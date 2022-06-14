import parseutils, strutils, strformat, strtabs,
       uri, options, mimetypes,
       os, osproc
       
import chronos, chronos/sendfile, chronos/streams/tlsstream

import response, tls, config

var m = newMimeTypes()
m.register(ext = "gemini", mimetype = "text/gemini")
m.register(ext = "gmi", mimetype = "text/gemini")

type
  Server = object
    impl: StreamServer
    settings: Settings

  Conn = object
    transp: StreamTransport
    mainWriter: AsyncStreamWriter
    mainReader: AsyncStreamReader
    writer: AsyncStreamWriter
    reader: AsyncStreamReader
    tls: TLSAsyncStream
  
  Protocol = enum
    ProtocolGemini = "gemini"
    ProtocolTitan = "titan"

  Resource = object
    uri: Uri
    rootDir, filePath, resPath: string
  
  Request = object
    conn: Conn
    cert: tls.Certificate
    
    res: Resource
    case protocol: Protocol
    of ProtocolTitan:
      params: seq[string]
    else: discard

proc requestGemini(conn: Conn, cert: tls.Certificate, res: Resource): Request =
  Request(conn: conn, cert: cert, res: res, protocol: ProtocolGemini)

proc requestTitan(conn: Conn, cert: tls.Certificate, res: Resource, params: seq[string]): Request =
  Request(conn: conn, cert: cert, res: res, protocol: ProtocolTitan, params: params)

proc getUserDir(path: string): (string, string) =
  var i = 2
  while i < path.len:
    if path[i] in {DirSep, AltSep}: break
    inc i

  result = (path[2..<i], path[i..^1])

template withAuthorityFile(filename: string, auth: untyped, body: untyped): untyped =
  const
    Separator = ':'
    Comment = '#'

  for line in lines(filename):
    if line[0] == Comment: continue
    
    var typToken: string
    let typCount = line.parseUntil(typToken, Separator)
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
    
    let auth: Authorisation = (typ, line.captureBetween(Separator, start = typCount).toUpperAscii)
    body

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
      return some response(RespRedirect, zone.val)
    of ZoneRedirectPerm:
      return some response(RespRedirectPerm, zone.val)
    of ZoneCgi:
      return some response(RespCGI, zone.val)
    of ZoneCert:
      if req.cert.len == 0:
        return some response(RespCertificateRequired, "A certificate is required to continue.")
      else:
        var authorised = false
        
        withAuthorityFile(zone.val, auth):
          #let certDigest = req.cert.getDigest(auth.typ)
          let certDigest = ""
          if certDigest == auth.digest:
            authorised = true
            break

        if authorised:
          return none(Response)
        else:
          return some response(RespNotAuthorised,
                               "The provided certificate is not authorized to access this resource.")
    else:
      return none(Response)

#[proc processCGI(server: Server, req: Request, script: string): Future[void] {.async.} =
  let
    scriptName = script.extractFileName()

  if not fileExists(script):
    await req.client.send $response(RespNotFound,
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
  
]#

#[proc processTitanRequest(server: Server, req: Request): Future[Response] {.async.} =
  let maybeZone = await server.processGeminiUri(req)
  if maybeZone.isSome(): return maybeZone.get()

  let titanSettings = server.settings.titanSettings

  var authorised = false
  if fileExists(titanSettings.authorisedCerts) and req.cert.len > 0:
    withAuthorityFile(titanSettings.authorisedCerts, auth):
      let certDigest = req.cert.getDigest(auth.typ)
      if certDigest == auth.digest:
        authorised = true
        break

  if not authorised:
    return response(RespNotAuthorised,
                    "The connection is unauthorised for uploading resources.")

  var size: int
  
  for i in 1..req.params.high:
    let keyVal = req.params[i].split("=")
    if keyVal.len != 2:
      return response(RespMalformedRequest, &"Bad parameter: '{req.params[i]}'.")
    
    if keyVal[0] == "size":
      try:
        size = keyVal[1].parseInt()
        if size <= 0: raise newException(ValueError, "Negative size")
      except ValueError:
        return response(RespMalformedRequest, &"Size '{keyVal[1]}' is invalid.")

  if size == 0:
    return response(RespMalformedRequest, "No file size specified.")

  if size > titanSettings.uploadLimit:
    return response(RespError, &"File size exceeds limit of {titanSettings.uploadLimit} bytes.")

  var filePath = req.res.filePath
  let (parent, _ ) = filePath.splitPath

  try:
    createDir(parent) # will simply succeed if it already exists
  except OSError:
    return response(RespError, &"Error writing to: '{req.res.resPath}'.")
  except IOError:
    return response(RespError, &"Could not create path: '{req.res.resPath}'.")

  if dirExists(filePath): # We're writing index.gmi in an existing directory
    filePath = filePath / "index.gmi"

  let buffer = await req.client.recv(size)
  try:
    writeFile(filePath, buffer)
  except:
    echo getCurrentExceptionMsg()
    return response(RespError, "")

  if titanSettings.redirect:
    var newUri = req.res.uri
    newUri.scheme = "gemini"

    return response(RespRedirect, $newUri)
  else:
      result = response(RespSuccessOther, "text/gemini")
      result.body = &"Succesfully wrote file '{req.res.resPath}'."
]#

proc serveFile(server: Server, path: string): Future[Response] {.async.} =
  result = response(RespSuccess, m.getMimetype(path.splitFile.ext))
  result.file = open(path)

#[proc serveDir(server: Server, path, resPath: string): Future[Response] {.async.} =
  template link(path: string): string =
    "=> " / path

  result = response(RespSuccessOther, "text/gemini")
  
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
]#

proc processGeminiRequest(server: Server, req: Request): Future[Response] {.async.} =
  let maybeZone = await server.processGeminiUri(req)

  result =
    if maybeZone.isSome(): maybeZone.get()
    elif fileExists(req.res.filePath):
      await server.serveFile(req.res.filePath)
    #[elif dirExists(req.res.filePath):
      await server.serveDir(req.res.filePath, req.res.resPath)]#

    else:
      response(RespNotFound, &"'{req.res.uri.path}' was not found.")
  
proc handle(server: Server, conn: Conn) {.async.} =
  let line = await conn.reader.readLine()
  
  #[case client.getVerifyResult()
  of CertOK: discard
  of CertExpired:
    await client.send $response(RespExpired, "The provided certificate has expired.")
    return
  of CertInvalid:
    await client.send $response(RespInvalid, "The provided certificate is invalid.")
    return
  ]#
  
  if line.len == 0:
    await conn.writer.write $response(RespMalformedRequest, "Empty request.")
    return
  
  if line.len > 1024:
    await conn.writer.write $response(RespMalformedRequest, "Request is too long.")
    return

  let uri = parseUri(line)
  if uri.hostname.len == 0 or uri.scheme.len == 0:
    await conn.writer.write $response(RespMalformedRequest, &"Request '{line}' is malformed.")
    return

  #let cert = client.getPeerCertificate()
  let cert = ""
  
  case uri.scheme
  of "gemini":
    let
      res = server.parseGeminiResource(uri)
      req = requestGemini(conn, cert, res)
      resp = await server.processGeminiRequest(req)
        
    case resp.code
    of RespNull:
      await conn.writer.write resp.meta
          
    of RespCGI:
      #await server.processCGI(req, resp.meta)
      discard
        
    else:
      await conn.writer.write $resp
      
      case resp.code
      of RespSuccess:
        #discard sendFile(int(rtransp.tsource.fd), int(resp.file.getFileHandle()), 0, count)
        await conn.writer.write resp.file.readAll
        resp.file.close()
        
            
      of RespSuccessOther:
        return
        #await client.send resp.body
          
      else: return

  of "titan": return
    #[let params = split(line, ";")
    if params.len < 2:
      await client.send $response(RespMalformedRequest)
        
    else:
      let
        res = server.parseGeminiResource(params[0].parseUri)
        req = requestTitan(client, cert, res, params)
        resp = await server.processTitanRequest(req)
            
      case resp.code
      of RespCGI:
        #await server.processCGI(req, resp.meta)
        discard
          
      else:
        await client.send $resp]#
             
  else:
    await conn.writer.write $response(RespProxyRefused, &"The protocol '{uri.scheme}' is unsuported.")

proc initServer(settings: Settings): Server =
  #[result.ctx = newContext(certFile = settings.certFile,
                          keyFile = settings.keyFile)
  result.ctx.prepareGeminiCtx()]#
  
  result.settings = settings
  
  let ta = initTAddress("127.0.0.1:" & $settings.port)
  result.impl = createStreamServer(ta, flags = {ReuseAddr, ReusePort})


proc acceptConn(server: Server): Future[Conn] {.async.} =
  let transp = await server.impl.accept()
  result = Conn(transp: transp,
                mainReader: newAsyncStreamReader(transp),
                mainWriter: newAsyncStreamWriter(transp))


  result.tls =
    newTLSServerAsyncStream(result.mainReader, result.mainWriter,
                            TLSPrivateKey.init(server.settings.keyFile.readFile),
                            TLSCertificate.init(server.settings.certFile.readFile),
                            minVersion = TLSVersion.TLS12)

  await handshake(result.tls)
  result.reader = AsyncStreamReader(result.tls.reader)
  result.writer = AsyncStreamWriter(result.tls.writer)
  
proc closeWait(conn: Conn): Future[void] =
  allFutures(conn.reader.closeWait(),
             conn.writer.closeWait(),
             conn.mainReader.closeWait(),
             conn.mainWriter.closeWait(),
             conn.transp.closeWait())

proc serve(server: Server) {.async.} =
  while true:
    let conn = await server.acceptConn()
    
    await server.handle(conn)
    await conn.writer.finish()
    await conn.closeWait()
      
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
