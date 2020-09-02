import net, asyncnet, asyncdispatch, asyncfile,
       uri, mimetypes, strutils, strtabs,
       os, osproc,
       openssl, md5

import config

const
  StatusInputRequired = 10
  StatusSuccess = 20
  StatusRedirect = 30
  StatusTempError = 40
  StatusError = 50
  StatusNotFound = 51
  StatusProxyRefused = 53
  StatusMalformedRequest = 59
  
type VHost = tuple
  hostname, rootDir: string

type Response = object
  code: int
  meta, body: string

var settings: Settings

var certMD5: string

var m = newMimeTypes()
m.register(ext = "gemini", mimetype = "text/gemini")
m.register(ext = "gmi", mimetype = "text/gemini")

proc SSL_CTX_set_session_id_context(ctx: SslCtx, id: string, idLen: int) {.importc, dynlib: DLLSSLName}

proc sslSetSessionIdContext(ctx: SslContext, id: string = "") =
  SSL_CTX_set_session_id_context(ctx.context, id, id.len)

proc isVirtDir(path, virtDir: string): bool =
  virtDir.len > 0 and
  path.extractFilename.len > 0 and
  path.parentDir == virtDir

proc getUserDir(path: string): (string, string) =
  var i = 2
  while i < path.len:
    if path[i] in {DirSep, AltSep}: break
    result[0].add path[i]
    inc i
  
  result[1] = path[i..^1]

proc serveScript(res: Uri, vhost: VHost): Future[Response] {.async.} =
  let
    query = res.query
    script = res.path.extractFilename
    scriptFile = settings.cgi.dir / script

  if not fileExists(scriptFile):
    return Response(code: StatusNotFound, meta: "CGI SCRIPT " & script & " NOT FOUND.")
  
  if query.len < 1:
    return Response(code: StatusInputRequired, meta: "ENTER INPUT ")

  putEnv("SCRIPT_NAME", script)
  putEnv("SCRIPT_FILENAME", scriptFile)
  putEnv("DOCUMENT_ROOT", vhost.rootDir)
  putEnv("SERVER_NAME", vhost.hostname)
  putEnv("SERVER_PORT", $settings.port)
  putEnv("QUERY_STRING", query)
  
  let (body, outp) = execCmdEx(scriptFile)
  
  if outp != 0:
    return Response(code: StatusError, meta: script & " FAILED WITH QUERY " & query)

  return Response(code: StatusSuccess, meta: "text/gemini", body: body)

proc serveFile(path: string): Future[Response] {.async.} =
  let file = openAsync(path)
  result.code = StatusSuccess
  result.body = await file.readAll()
  file.close()

  if result.body.len > 0:
    result.meta = m.getMimetype(path.splitFile.ext.toLowerAscii)
  else:
    result.meta = "text/gemini"
    result.body = "##<Empty File>"

proc serveDir(path, resPath: string): Future[Response] {.async.} =
  template link(path: string): string =
    "=> " / path

  result.code = StatusSuccess
  result.meta = "text/gemini"
  
  result.body.add "### Index of " & resPath.normalizedPath & "\r\n"
  if resPath.parentDir != "":
    result.body.add link(resPath.splitPath.head) & " [..]" & "\r\n"
  
  for kind, file in path.walkDir:
    let fileName = file.extractFilename
    if fileName.toLowerAscii == "index.gemini" or
       fileName.toLowerAscii == "index.gmi":
      return await serveFile(file)
    
    result.body.add link(resPath / fileName) & ' ' & fileName
    case kind:
    of pcFile: result.body.add " [FILE]"
    of pcDir: result.body.add " [DIR]"
    of pcLinkToFile, pcLinkToDir: result.body.add " [SYMLINK]"
    result.body.add "\r\n"

proc parseRequest(line: string): Future[Response] {.async.} =
  let res = parseUri(line)
  
  if not res.isAbsolute:
    return Response(code: StatusMalformedRequest, meta: "MALFORMED REQUEST")
  
  if settings.redirects.hasKey(res.hostname):
    return Response(code: StatusRedirect, meta: settings.redirects[res.hostname])
    
  elif settings.vhosts.hasKey(res.hostname):
    let vhost = (hostname: res.hostname,
                   rootDir: settings.vhosts[res.hostname])
    var
      rootDir = vhost.rootDir
      filePath = rootDir / res.path
      
    if res.path.startsWith("/~"):
      let (user, newPath) = res.path.getUserDir
      rootDir = settings.homeDir % [user] / vhost.hostname
      filePath = rootDir / newPath

    var resPath = res.path
    if not filePath.startsWith(rootDir):
      filePath = vhost.rootDir
      resPath = "/"
    
    if res.path.isVirtDir(settings.cgi.virtDir):
      return await serveScript(res, vhost)
    elif fileExists(filePath):
      return await serveFile(filePath)
    elif dirExists(filePath):
      return await serveDir(filePath, resPath)
    else:
      return Response(code: StatusNotFound, meta: "'" & res.path & "' NOT FOUND")

  else:
    return Response(code: StatusProxyRefused, meta: "PROXY REFUSED")

proc handle(client: AsyncSocket) {.async.} =
  let line = await client.recvLine()
  if line.len > 0:
    echo line
    try:
      let resp = await parseRequest(line)
      await client.send($resp.code & ' ' & resp.meta & "\r\n")
      if resp.code == StatusSuccess:
        await client.send(resp.body)
    except:
      await client.send("40 INTERNAL ERROR\r\n")
      echo getCurrentExceptionMsg()
      
  client.close()

proc serve() {.async.} =
  let ctx = newContext(certFile = settings.certFile,
                       keyFile = settings.keyFile)

  var server = newAsyncSocket()
  server.setSockOpt(OptReuseAddr, true)
  server.setSockOpt(OptReusePort, true)
  server.bindAddr(Port(settings.port))
  server.listen()
  ctx.wrapSocket(server)
  ctx.sslSetSessionIdContext(id = certMD5)
  while true:
    try:
      let client = await server.accept()
      ctx.wrapConnectedSocket(client, handshakeAsServer)
      await client.handle()
    except:
      echo getCurrentExceptionMsg()

if paramCount() != 1:
  echo "USAGE:"
  echo "./geminim <path/to/config.ini>"
elif fileExists(paramStr(1)):
  settings = readSettings(paramStr(1))
  certMD5 = readFile(settings.certFile).getMD5()
  waitFor serve()
  runForever()
else:
  echo paramStr(1) & ": file not found"
