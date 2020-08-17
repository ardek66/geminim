import net, asyncnet, asyncdispatch, uri, os, mimetypes, strutils

type Response = object
  code: int
  meta, body: string

const
  hostname = "localhost"
  dir = "pub"

let ctx = newContext(certFile="mycert.pem", keyFile="mykey.pem")
var m = newMimeTypes()
m.register(ext = "gemini", mimetype = "text/gemini")
m.register(ext = "gmi", mimetype = "text/gemini")

template linkFromPath(path: string): string =
  "=> gemini://" & hostname / path

proc serveFile(response: var Response, path: string) =
  response.body = readFile(path)
  if response.body.len > 0:
    response.meta = m.getMimetype(path.splitFile.ext.toLowerAscii)
  else:
    response.body = "##<Empty File>"
    response.meta = "text/gemini"

proc serveDir(response: var Response, path: string) =
  let relPath = path.relativePath(dir)
  
  response.body.add "### Index of " & relPath & "\r\n"
  if relPath.parentDir != "":
    response.body.add linkFromPath(relPath.parentDir) & " [..]" & "\r\n"
  
  for kind, file in path.walkDir:
    let uriPath = relativePath(file, dir, '/')
    if uriPath.toLowerAscii == "index.gemini" or
       uriPath.toLowerAscii == "index.gmi":
      response.serveFile(file)
      return
    
    response.body.add linkFromPath(uriPath) & ' ' & uriPath.extractFilename
    case kind:
    of pcFile: response.body.add " [FILE]"
    of pcDir: response.body.add " [DIR]"
    of pcLinkToFile, pcLinkToDir: response.body.add " [SYMLINK]"
    response.body.add "\r\n"
    
  if response.body.len == 0: response.body = "Directory is empty"
  response.meta = "text/gemini"

proc parseRequest(client: AsyncSocket, line: string) {.async.} =
  let res = parseUri(line)
  var path = dir & res.path
  if path.relativePath(dir).parentDir == "": path = dir

  var response: Response

  if res.hostname != hostname:
    response.code = 53
    response.meta = "PROXY NOT ALLOWED"
  else:
    response.code = 20
    if fileExists(path):
      response.serveFile(path)
    elif dirExists(path):
      response.serveDir(path)
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
  var server = newAsyncSocket()
  server.setSockOpt(OptReuseAddr, true)
  server.setSockOpt(OptReusePort, true)
  server.bindAddr(Port(1965))
  server.listen()
  ctx.wrapSocket(server)
  while true:
    let client = await server.accept()
    ctx.wrapConnectedSocket(client, handshakeAsServer)
    asyncCheck client.handle()

waitFor serve()
