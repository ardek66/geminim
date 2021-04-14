import net, streams, asyncnet, asyncdispatch,
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
  meta: string
  bodyStream: Stream

var settings: Settings

var certMD5: string

var m = newMimeTypes()
m.register(ext = "gemini", mimetype = "text/gemini")
m.register(ext = "gmi", mimetype = "text/gemini")


template fileResponse(path: string): Response =
  Response(code: StatusSuccess,
           bodyStream: newFileStream(path),
           meta: m.getMimetype(toLowerAscii(path.splitFile.ext)))
      
proc isVirtDir(path, virtDir: string): bool =
  virtDir.len > 0 and
  path.extractFilename.len > 0 and
  path.parentDir == virtDir

proc getUserDir(path: string): (string, string) =
  var i = 2
  while i < path.len:
    if path[i] in {DirSep, AltSep}: break
    inc i

  result = (path[2..<i], path[i..^1])

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

  return Response(code: StatusSuccess, meta: "text/gemini",
                  bodyStream: newStringStream(body))

proc serveDir(path, resPath: string): Future[Response] {.async.} =
  template link(path: string): string =
    "=> " / path
  
  result.code = StatusSuccess
  result.meta = "text/gemini"
  result.bodyStream = newStringStream()
  
  let headerPath = path / settings.dirHeader
  if fileExists(headerPath):
    let banner = readFile(headerPath)
    result.bodyStream.write banner & "\n"
  
  result.bodyStream.write "### Index of " & resPath.normalizedPath & "\n"
  
  if resPath.parentDir != "":
    result.bodyStream.write link(resPath.splitPath.head) & " [..]" & "\n"
  for kind, file in path.walkDir:
    let fileName = file.extractFilename
    if fileName.toLowerAscii == "index.gemini" or
       fileName.toLowerAscii == "index.gmi":
      return fileResponse(file)
    
    result.bodyStream.write link(resPath / fileName) & ' ' & fileName
    case kind:
    of pcFile: result.bodyStream.write " [FILE]"
    of pcDir: result.bodyStream.write " [DIR]"
    of pcLinkToFile, pcLinkToDir: result.bodyStream.write " [SYMLINK]"
    result.bodyStream.write "\n"

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

    if fileExists(filePath):
      return fileResponse(filePath)
    elif dirExists(filePath):
      return await serveDir(filePath, resPath)
    elif res.path.isVirtDir(settings.cgi.virtDir):
      return await serveScript(res, vhost)
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
        resp.bodyStream.setPosition(0)
        while not resp.bodyStream.atEnd():
          await client.send resp.bodyStream.readStr(4096)
        resp.bodyStream.close()
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
  
  var client: AsyncSocket
  while true:
    try:
      client = await server.accept()
      ctx.wrapConnectedSocket(client, handshakeAsServer)
      await client.handle()
      client.close()
    except:
      echo getCurrentExceptionMsg()

if paramCount() != 1:
  echo "USAGE:"
  echo "./geminim <path/to/config.ini>"
elif fileExists(paramStr(1)):
  settings = readSettings(paramStr(1))
  certMD5 = readFile(settings.certFile).getMD5()
  waitFor serve()
else:
  echo paramStr(1) & ": file not found"
