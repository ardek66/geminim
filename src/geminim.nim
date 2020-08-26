import net, asyncnet, asyncdispatch, asyncfile,
       uri, mimetypes, strutils, strtabs,
       os, osproc

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

var m = newMimeTypes()
m.register(ext = "gemini", mimetype = "text/gemini")
m.register(ext = "gmi", mimetype = "text/gemini")

template resp(): Response =
  response.mget()
  
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

proc serveScript(response: FutureVar[Response], res: Uri, vhost: VHost) {.async.} =
  let
    query = res.query
    script = res.path.extractFilename
    scriptFile = settings.cgi.dir / script

  if not fileExists(scriptFile):
    resp.code = StatusNotFound
    resp.meta = "CGI SCRIPT " & script & " NOT FOUND."
    return
  
  if query.len < 1:
    resp.code = StatusInputRequired
    resp.meta = "ENTER INPUT "
    return

  putEnv("SCRIPT_NAME", script)
  putEnv("SCRIPT_FILENAME", scriptFile)
  putEnv("DOCUMENT_ROOT", vhost.rootDir)
  putEnv("SERVER_NAME", vhost.hostname)
  putEnv("SERVER_PORT", $settings.port)
  putEnv("QUERY_STRING", query)
  
  var outp: int
  (resp.body, outp) = execCmdEx(scriptFile)
  
  if outp != 0:
    resp.code = StatusError
    resp.meta = script & " FAILED WITH QUERY " & query

proc serveFile(response: FutureVar[Response], path: string) {.async.} =
  let file = openAsync(path)
  resp.body = await file.readAll()
  file.close()
  
  if resp.body.len > 0:
    resp.meta = m.getMimetype(path.splitFile.ext.toLowerAscii)
  else:
    resp.body = "##<Empty File>"

proc serveDir(response: FutureVar[Response], path, resPath: string) {.async.} =
  template link(path: string): string =
    "=> " / path
  
  resp.body.add "### Index of " & resPath & "\r\n"
  if resPath.parentDir != "":
    resp.body.add link(resPath.parentDir) & " [..]" & "\r\n"
  
  for kind, file in path.walkDir:
    let fileName = file.extractFilename
    if fileName.toLowerAscii == "index.gemini" or
       fileName.toLowerAscii == "index.gmi":
      await response.serveFile(file)
      return
    
    resp.body.add link(resPath / fileName) & ' ' & fileName
    case kind:
    of pcFile: resp.body.add " [FILE]"
    of pcDir: resp.body.add " [DIR]"
    of pcLinkToFile, pcLinkToDir: resp.body.add " [SYMLINK]"
    resp.body.add "\r\n"
  
  if resp.body.len == 0: resp.body = "Directory is empty"

proc parseRequest(client: AsyncSocket, line: string) {.async.} =
  let res = parseUri(line)
  var response = newFutureVar[Response]("parseRequest")

  if res.isAbsolute:
  
    if settings.redirects.hasKey(res.hostname):
      resp.code = StatusRedirect
      resp.meta = settings.redirects[res.hostname]
    
    elif settings.vhosts.hasKey(res.hostname):
      let vhost = (hostname: res.hostname,
                   rootDir: settings.vhosts[res.hostname])
      var
        rootDir = vhost.rootDir
        relPath = rootDir / res.path
        filePath = relPath
      
      if res.path.startsWith("/~"):
        let (user, newPath) = res.path.getUserDir
        rootDir = vhost.hostname
        relPath = rootDir / newPath
        filePath = settings.homeDir / user / relPath
      
      var resPath = res.path
      if not (relPath.normalizedPath.startsWith(rootDir)):
        filePath = vhost.rootDir
        resPath = "/"
    
      resp.code = StatusSuccess
      resp.meta = "text/gemini"
    
      if res.path.isVirtDir(settings.cgi.virtDir):
        await response.serveScript(res, vhost)
      elif fileExists(filePath):
        await response.serveFile(filePath)
      elif dirExists(filePath):
        await response.serveDir(filePath, resPath)
      else:
        resp.code = StatusNotFound
        resp.meta = "'" & res.path & "' NOT FOUND"

    else:
      resp.code = StatusProxyRefused
      resp.meta = "PROXY REFUSED"
      
  else:
    resp.code = StatusMalformedRequest
    resp.meta = "MALFORMED REQUEST"

  try:
    await client.send($resp.code & " " & resp.meta & "\r\n")
    if resp.code == StatusSuccess:
      await client.send(resp.body)
  except:
    let msg = getCurrentExceptionMsg()
    await client.send("40 TEMP ERROR " & msg & "\r\n")

proc handle(client: AsyncSocket) {.async.} =
  let line = await client.recvLine()
  echo line
  if line.len == 0:
    echo "client disconnected"
    client.close()
    return
  await client.parseRequest(line)
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
  while true:
    let client = await server.accept()
    ctx.wrapConnectedSocket(client, handshakeAsServer)
    await client.handle()

if paramCount() != 1:
  echo "USAGE:"
  echo "./geminim <path/to/config.ini>"
elif fileExists(paramStr(1)):
  settings = readSettings(paramStr(1))
  waitFor serve()
  runForever()
else:
  echo paramStr(1) & ": file not found"
