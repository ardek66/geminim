import net, asyncnet, asyncdispatch,
       uri, os, mimetypes, strutils, strtabs

import config

type Response = object
  code: int
  meta, body: string

var settings: Settings

var m = newMimeTypes()
m.register(ext = "gemini", mimetype = "text/gemini")
m.register(ext = "gmi", mimetype = "text/gemini")

template link(hostname, path: string): string =
  "=> gemini://" & hostname / path

proc serveFile(response: var Response, path: string) =
  response.body = readFile(path)
  if response.body.len > 0:
    response.meta = m.getMimetype(path.splitFile.ext.toLowerAscii)
  else:
    response.body = "##<Empty File>"
    response.meta = "text/gemini"

proc serveDir(response: var Response, path, hostname, rootDir: string) =
  let relPath = path.relativePath(rootDir)
  
  response.body.add "### Index of " & relPath & "\r\n"
  if relPath.parentDir != "":
    response.body.add link(hostname, relPath.parentDir) & " [..]" & "\r\n"
  
  for kind, file in path.walkDir:
    let uriPath = relativePath(file, rootDir, '/')
    if uriPath.toLowerAscii == "index.gemini" or
       uriPath.toLowerAscii == "index.gmi":
    let
      uriPath = relativePath(file, rootDir, '/')
      uriFile = uriPath.extractFilename
    
    if uriFile.toLowerAscii == "index.gemini" or
       uriFile.toLowerAscii == "index.gmi":
      response.serveFile(file)
      return
    
    response.body.add link(hostname, uriPath) & ' ' & uriFile
    case kind:
    of pcFile: response.body.add " [FILE]"
    of pcDir: response.body.add " [DIR]"
    of pcLinkToFile, pcLinkToDir: response.body.add " [SYMLINK]"
    response.body.add "\r\n"
    
  if response.body.len == 0: response.body = "Directory is empty"
  response.meta = "text/gemini"

proc parseRequest(client: AsyncSocket, line: string) {.async.} =
  let res = parseUri(line)
  
  if settings.vhost.hasKey(res.hostname):
    let
      hostname = res.hostname
      rootDir = settings.vhost[hostname]
    
    var path = rootDir & res.path
    path.normalizePath
    if path.startsWith "..":
      path = rootDir

    var response: Response
    response.code = 20
    if fileExists(path):
      response.serveFile(path)
    elif dirExists(path):
      response.serveDir(path, hostname, rootDir)
    else:
      response.code = 51
      response.meta = "'" & path & "' NOT FOUND"
    
    try:
      await client.send($response.code & " " & response.meta & "\r\n")
      if response.code == 20:
        await client.send(response.body)
    except:
      let msg = getCurrentExceptionMsg()
      await client.send("40 TEMP ERROR " & msg & "\r\n")

  else:
    await client.send("53 PROXY NOT SUPPORTED\r\n")

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
  let ctx = newContext(certFile = settings.certFile, keyFile = settings.keyFile)
  var server = newAsyncSocket()
  server.setSockOpt(OptReuseAddr, true)
  server.setSockOpt(OptReusePort, true)
  server.bindAddr(Port(settings.port))
  server.listen()
  ctx.wrapSocket(server)
  while true:
    let client = await server.accept()
    ctx.wrapConnectedSocket(client, handshakeAsServer)
    asyncCheck client.handle()

if paramCount() != 1:
  echo "USAGE:"
  echo "./geminim <path/to/config.ini>"
elif fileExists(paramStr(1)):
  settings = readSettings(paramStr(1))
  waitFor serve()
else:
  echo paramStr(1) & ": file not found"
