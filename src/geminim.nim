import net, asyncnet, asyncdispatch, asyncfile,
       uri, strutils, strtabs, streams, options,
       os, osproc, md5, mimetypes

import response, config

var m = newMimeTypes()
m.register(ext = "gemini", mimetype = "text/gemini")
m.register(ext = "gmi", mimetype = "text/gemini")

type
  Server = object
    socket: AsyncSocket
    ctx: SslContext
    settings: Settings
    certMD5: string

  Protocol = enum
    ProtocolGemini = "gemini"
    ProtocolTitan = "titan"

  Resource = object
    uri: Uri
    rootDir, filePath, resPath: string
  
  Request = object
    client: AsyncSocket
    res: Resource

    case protocol: Protocol
    of ProtocolTitan:
      params: seq[string]
    else: discard

proc requestGemini(client: AsyncSocket, res: Resource): Request =
  Request(client: client, res: res, protocol: ProtocolGemini)

proc requestTitan(client: AsyncSocket, res: Resource, params: seq[string]): Request =
  Request(client: client, res: res, protocol: ProtocolTitan, params: params)

proc initServer(settings: Settings): Server =
  result.ctx = newContext(certFile = settings.certFile,
                          keyFile = settings.keyFile)

  result.settings = settings
  result.certMD5 = readFile(settings.certFile).getMD5()
  result.socket = newAsyncSocket()

proc getUserDir(path: string): (string, string) =
  var i = 2
  while i < path.len:
    if path[i] in {DirSep, AltSep}: break
    inc i

  result = (path[2..<i], path[i..^1])

proc parseGeminiResource(server: Server, uri: Uri): Resource =
  let vhostRoot = server.settings.rootDir / uri.hostname
  result = Resource(rootDir: vhostRoot, filePath: vhostRoot / uri.path, resPath: uri.path)
  
  if uri.path.startsWith("/~"):
    let (user, newPath) = uri.path.getUserDir
    result.rootDir = server.settings.homeDir % [user] / uri.hostname
    result.filePath = result.rootDir / newPath
  
  if not result.filePath.startsWith result.rootDir:
    result.filePath = vhostRoot
    result.resPath = "/"

proc processGeminiUri(server: Server, req: Request): Option[Response] =
  if server.settings.vhosts.hasKey req.res.uri.hostname:
    let zone = server.settings.vhosts[req.res.uri.hostname].findZone(req.res.resPath)
    result = case zone.ztype
             of ZoneRedirect:
               some response(StatusRedirect, zone.val)
             of ZoneRedirectPerm:
               some response(StatusRedirectPerm, zone.val)
             of ZoneCgi:
               some response(StatusCGI, zone.val)
             else: none(Response)

proc processCGI(server: Server, req: Request, script: string): Future[void] {.async.} =
  let
    scriptName = script.extractFileName()

  if not fileExists(script):
    await req.client.send strResp(StatusNotFound, "CGI SCRIPT " & scriptName & " NOT FOUND.")
  else:
    let envTable =
      {
        "SCRIPT_NAME": scriptName,
        "SCRIPT_FILENAME": script,
        "SERVER_NAME": req.res.uri.hostname,
        "SERVER_PORT": $server.settings.port,
        "PATH_INFO": req.res.uri.path,
        "QUERY_STRING": req.res.uri.query,
        "REQUEST_URI": $req.res.uri
      }.newStringTable

    var p = startProcess(script, env = envTable)
    while not p.outputStream.atEnd:
      await req.client.send p.outputStream.readStr(BufferSize)
    p.close()
  

proc processTitanRequest(server: Server, req: Request): Future[Response] {.async.} =
  let maybeZone = server.processGeminiUri(req)
  if maybeZone.isSome(): return maybeZone.get()

  var 
    size: int
    token: string
  
  for i in 0..req.params.high:
    if i == 0: # actual path
      continue 

    let keyVal = req.params[i].split("=")
    if keyVal.len != 2:
      return response(StatusMalformedRequest, "Bad parameter: " & req.params[i])
    if keyVal[0] == "size":
      try:
        size = keyVal[1].parseInt()
      except ValueError:
        return response(StatusMalformedRequest, "Size " & keyVal[1] & " is invalid")
    if keyVal[0] == "token":
      token = keyVal[1].decodeUrl

  if size == 0:
    return response(StatusMalformedRequest, "No file size specified")
  if size > server.settings.titanUploadLimit:
    return response(StatusError,
      "File size exceeds limit of " & $server.settings.titanUploadLimit & " bytes.")

  if token != server.settings.titanPass and server.settings.titanPassRequired:
    return response(StatusNotAuthorised, "Token not recognized")

  var filePath = req.res.filePath
  if dirExists(filePath):
    filePath = filePath / "index.gmi" # assume we want to write index.gmi

  let buffer = await req.client.recv(size)
  try:
    let file = openAsync(filePath, fmWrite)

    await file.write(buffer)
    file.close()
  except:
    echo getCurrentExceptionMsg()
    return response(StatusError, "")

  result = response(StatusSuccess, "text/gemini\r\nSuccessfully wrote file")


proc serveFile(server: Server, path: string): Future[Response] {.async.} =
  result = response(StatusSuccess, m.getMimetype(path.splitFile.ext))
  result.file = openAsync(path)

proc serveDir(server: Server, path, resPath: string): Future[Response] {.async.} =
  template link(path: string): string =
    "=> " / path

  result = response(StatusSuccessDir, "text/gemini")
  
  let headerPath = path / server.settings.dirHeader
  if fileExists(headerPath):
    let banner = readFile(headerPath)
    result.body.add banner & "\n"
  
  result.body.add "### Index of " & resPath.normalizedPath & "\n"
  
  if resPath.parentDir != "":
    result.body.add link(resPath.splitPath.head) & " [..]" & "\n"
  for kind, file in path.walkDir:
    let fileName = file.extractFilename
    if fileName.toLowerAscii in ["index.gemini", "index.gmi"]:
      return await server.serveFile(file)
    
    result.body.add link(resPath / fileName) & ' ' & fileName
    case kind:
    of pcFile: result.body.add " [FILE]"
    of pcDir: result.body.add " [DIR]"
    of pcLinkToFile, pcLinkToDir: result.body.add " [SYMLINK]"
    result.body.add "\n"

proc processGeminiRequest(server: Server, req: Request): Future[Response] {.async.} =
  let maybeZone = server.processGeminiUri(req)

  if maybeZone.isSome():
    return maybeZone.get()
  elif fileExists(req.res.filePath):
    return await server.serveFile(req.res.filePath)
  elif dirExists(req.res.filePath):
    return await server.serveDir(req.res.filePath, req.res.resPath)
    
  return response(StatusNotFound, "'" & req.res.uri.path & "' NOT FOUND")
  
proc handle(server: Server, client: AsyncSocket) {.async.} =
  server.ctx.wrapConnectedSocket(client, handshakeAsServer)
  
  try:
    let line = await client.recvLine()
    if line.len > 0:
      echo line

      if(line.len > 1024):
        await client.send strResp(StatusMalformedRequest, "REQUEST IS TOO LONG.")
      
      let uri = parseUri(line)
      if uri.hostname.len == 0 or uri.scheme.len == 0:
        await client.send strResp(StatusMalformedRequest, "MALFORMED REQUEST: '" & line & "'.")

      
      case uri.scheme
      of "gemini":
        let
          res = server.parseGeminiResource(uri)
          req = requestGemini(client, res)
          resp = await server.processGeminiRequest(req)
        
        case resp.code
        of StatusNull:
          await client.send resp.meta
          
        of StatusCGI:
          await server.processCGI(req, resp.meta)
        
        else:
          await client.send strResp(resp.code, resp.meta)
      
          case resp.code
          of StatusSuccess:
            while true:
              let buffer = await resp.file.read(BufferSize)
              if buffer.len < 1: break
              await client.send buffer
            resp.file.close()
            
          of StatusSuccessDir:
            await client.send resp.body
          
          else: discard

      of "titan":
        let params = split(line, ";")
        if params.len < 2:
          await client.send strResp(StatusMalformedRequest)
        
        else:
          let
            res = server.parseGeminiResource(params[0].parseUri)
            req = requestTitan(client, res, params)
            resp = await server.processTitanRequest(req)
            
          case resp.code
          of StatusCGI:
            await server.processCGI(req, resp.meta)
          
          else:
            await client.send strResp(resp.code, resp.meta)
             
      else:
        await client.send strResp(StatusMalformedRequest, "UNSUPORTED PROTOCOL: '" & uri.scheme & "'.")
          
  except:
    await client.send TempErrorResp
    echo getCurrentExceptionMsg()
      
  client.close()

proc serve(server: Server) {.async.} =
  server.ctx.sessionIdContext = server.certMD5
  server.ctx.wrapSocket(server.socket)
  
  server.socket.setSockOpt(OptReuseAddr, true)
  server.socket.setSockOpt(OptReusePort, true)
  server.socket.bindAddr(Port(server.settings.port))
  server.socket.listen()

  while true:
    try:
      let client = await server.socket.accept()
      yield server.handle(client)
    except:
      echo getCurrentExceptionMsg()

proc main() =
  if paramCount() != 1:
    echo "USAGE:"
    echo "./geminim <path/to/config.ini>"
  else:
    let file = paramStr(1)
    if fileExists(file):
      let server = initServer(file.readSettings)
      waitFor server.serve()
    else:
      echo file & ": file not found"

main()
