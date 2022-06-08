import net, asyncnet, asyncdispatch, asyncfile,
       uri, parseutils, strutils, strformat, strtabs, streams,
       options,
       os, osproc, md5, mimetypes

import response, tls, config

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
    cert: Certificate
    
    res: Resource
    case protocol: Protocol
    of ProtocolTitan:
      params: seq[string]
    else: discard

proc requestGemini(client: AsyncSocket, cert: Certificate, res: Resource): Request =
  Request(client: client, cert: cert, res: res, protocol: ProtocolGemini)

proc requestTitan(client: AsyncSocket, cert: Certificate, res: Resource, params: seq[string]): Request =
  Request(client: client, cert: cert, res: res, protocol: ProtocolTitan, params: params)

proc initServer(settings: Settings): Server =
  result.ctx = newContext(certFile = settings.certFile,
                          keyFile = settings.keyFile)
  result.ctx.prepareGeminiCtx()
  
  result.settings = settings
  result.certMD5 = readFile(settings.certFile).getMD5()
  result.socket = newAsyncSocket()

proc getUserDir(path: string): (string, string) =
  var i = 2
  while i < path.len:
    if path[i] in {DirSep, AltSep}: break
    inc i

  result = (path[2..<i], path[i..^1])

template withAuthorityFile(filename: string, auth: untyped, body: untyped): untyped =
  let file = openAsync(filename)

  while true:
    let line = await file.readLine()
    if line.len < 1: break
    if line[0] == '#': continue
    
    var typToken: string
    let typCount = line.parseUntil(typToken, '!')
    if typCount == line.len:
      echo "Invalid authorization field: " & line
      continue

    let typ =
      case typToken
      of "md5": DigestMD5
      of "sha1": DigestSHA1
      of "sha256": DigestSHA256
      of "sha512": DigestSHA512
      else: DigestErr

    if typ == DigestErr:
      echo "Invalid digest type: " & typToken
      continue
    
    let auth: Authorisation = (typ, line.captureBetween('!', start = typCount).toUpperAscii)
    body

  file.close()

proc parseGeminiResource(server: Server, uri: Uri): Resource =
  let vhostRoot = server.settings.rootDir / uri.hostname
  result = Resource(rootDir: vhostRoot, filePath: vhostRoot / uri.path, resPath: uri.path, uri: uri)
  
  if uri.path.startsWith("/~"):
    let (user, newPath) = uri.path.getUserDir
    result.rootDir = server.settings.homeDir % [user] / uri.hostname
    result.filePath = result.rootDir / newPath
  
  if not result.filePath.startsWith result.rootDir:
    result.filePath = vhostRoot
    result.resPath = "/"

proc processGeminiUri(server: Server, req: Request): Future[Option[Response]] {.async.} =
  let hostname = req.res.uri.hostname
  
  if server.settings.vhosts.hasKey hostname:
    let zone = server.settings.vhosts[hostname].findZone(req.res.resPath)
    case zone.ztype
    of ZoneRedirect:
      return some response(StatusRedirect, zone.val)
    of ZoneRedirectPerm:
      return some response(StatusRedirectPerm, zone.val)
    of ZoneCgi:
      return some response(StatusCGI, zone.val)
    of ZoneCert:
      if req.cert.len == 0:
        return some response(StatusCertificateRequired, "A certificate is required to continue.")
      else:
        var authorised = false
        
        withAuthorityFile(zone.val, auth):
          let certDigest = req.cert.getDigest(auth.typ)
          if certDigest == auth.digest:
            authorised = true
            break

        if authorised:
          return none(Response)
        else:
          return some response(StatusNotAuthorised,
                               "The provided certificate is not authorized to access this resource.")
    else:
      return none(Response)

proc processCGI(server: Server, req: Request, script: string): Future[void] {.async.} =
  let
    scriptName = script.extractFileName()

  if not fileExists(script):
    await req.client.send $response(StatusNotFound,
                                    &"The CGI script '{scriptName}' could not be found.")
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
  let maybeZone = await server.processGeminiUri(req)
  if maybeZone.isSome(): return maybeZone.get()

  var 
    size: int
    token: string
  
  for i in 1..req.params.high:
    let keyVal = req.params[i].split("=")
    if keyVal.len != 2:
      return response(StatusMalformedRequest, &"Bad parameter: '{req.params[i]}'.")
    
    if keyVal[0] == "size":
      try:
        size = keyVal[1].parseInt()
        if size <= 0: raise newException(ValueError, "Negative size")
      except ValueError:
        return response(StatusMalformedRequest, &"Size '{keyVal[1]}' is invalid.")
    
    if keyVal[0] == "token":
      token = keyVal[1].decodeUrl

  if size == 0:
    return response(StatusMalformedRequest, "No file size specified.")
  
  let titanSettings = server.settings.titanSettings

  if size > titanSettings.uploadLimit:
    return response(StatusError, &"File size exceeds limit of {titanSettings.uploadLimit} bytes.")

  if token != titanSettings.password and titanSettings.passwordRequired:
    return response(StatusNotAuthorised, "Token not recognized.")

  var filePath = req.res.filePath
  let (parent, _ ) = filePath.splitPath

  try:
    createDir(parent) # will simply succeed if it already exists
  except OSError:
    return response(StatusError, &"Error writing to: '{req.res.resPath}'.")
  except IOError:
    return response(StatusError, &"Could not create path: '{req.res.resPath}'.")

  if dirExists(filePath): # We're writing index.gmi in an existing directory
    filePath = filePath / "index.gmi"

  let buffer = await req.client.recv(size)
  try:
    let file = openAsync(filePath, fmWrite)

    await file.write(buffer)
    file.close()
  except:
    echo getCurrentExceptionMsg()
    return response(StatusError, "")

  if titanSettings.redirect:
    var newUri = req.res.uri
    newUri.scheme = "gemini"

    return response(StatusRedirect, $newUri)
  else:
      result = response(StatusSuccessOther, "text/gemini")
      result.body = &"Succesfully wrote file '{req.res.resPath}'."

proc serveFile(server: Server, path: string): Future[Response] {.async.} =
  result = response(StatusSuccess, m.getMimetype(path.splitFile.ext))
  result.file = openAsync(path)

proc serveDir(server: Server, path, resPath: string): Future[Response] {.async.} =
  template link(path: string): string =
    "=> " / path

  result = response(StatusSuccessOther, "text/gemini")
  
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
  let maybeZone = await server.processGeminiUri(req)

  result =
    if maybeZone.isSome(): maybeZone.get()
    elif fileExists(req.res.filePath):
      await server.serveFile(req.res.filePath)
    elif dirExists(req.res.filePath):
      await server.serveDir(req.res.filePath, req.res.resPath)

    else:
      response(StatusNotFound, &"'{req.res.uri.path}' was not found.")
  
proc handle(server: Server, client: AsyncSocket) {.async.} =
  server.ctx.wrapConnectedSocket(client, handshakeAsServer)
  
  let line = await client.recvLine()

  case client.getVerifyResult()
  of CertOK: discard
  of CertExpired:
    await client.send $response(StatusExpired, "The provided certificate has expired.")
    return
  of CertInvalid:
    await client.send $response(StatusInvalid, "The provided certificate is invalid.")
    return
  
  if line.len == 0:
    await client.send $response(StatusMalformedRequest, "Empty request.")
    return
  
  if line.len > 1024:
    await client.send $response(StatusMalformedRequest, "Request is too long.")
    return

  let uri = parseUri(line)
  if uri.hostname.len == 0 or uri.scheme.len == 0:
    await client.send $response(StatusMalformedRequest, "Request '{line}' is malformed.")
    return

  let cert = client.getPeerCertificate()
  
  case uri.scheme
  of "gemini":
    let
      res = server.parseGeminiResource(uri)
      req = requestGemini(client, cert, res)
      resp = await server.processGeminiRequest(req)
        
    case resp.code
    of StatusNull:
      await client.send resp.meta
          
    of StatusCGI:
      await server.processCGI(req, resp.meta)
        
    else:
      await client.send $resp
      
      case resp.code
      of StatusSuccess:
        while true:
          let buffer = await resp.file.read(BufferSize)
          if buffer.len < 1: break
          await client.send buffer
        resp.file.close()
            
      of StatusSuccessOther:
        await client.send resp.body
          
      else: return

  of "titan":
    let params = split(line, ";")
    if params.len < 2:
      await client.send $response(StatusMalformedRequest)
        
    else:
      let
        res = server.parseGeminiResource(params[0].parseUri)
        req = requestTitan(client, cert, res, params)
        resp = await server.processTitanRequest(req)
            
      case resp.code
      of StatusCGI:
        await server.processCGI(req, resp.meta)
          
      else:
        await client.send $resp
             
  else:
    await client.send $response(StatusProxyRefused, &"The protocol '{uri.scheme}' is unsuported.")

proc serve(server: Server) {.async.} =
  server.ctx.sessionIdContext = server.certMD5
  server.socket.setSockOpt(OptReuseAddr, true)
  server.socket.setSockOpt(OptReusePort, true)
  server.socket.bindAddr(Port(server.settings.port))

  server.ctx.wrapSocket(server.socket)
  server.socket.listen()

  while true:
    let
      client = await server.socket.accept()
      future = server.handle(client)

    yield future
    if future.failed:
      await client.send $response(StatusTempError, "Internal error.")
      echo future.error.msg

    client.close()
      
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
      echo &"{file}: file not found."

main()
