import openssl, strutils, net, asyncnet
export openssl

proc PEM_read_bio_X509(bio: BIO, x: PX509, password_cb: cint, u: pointer): PX509 {.importc, dynlib: DLLSSLName.}
proc SSL_CTX_set_verify_depth(ctx: SslCtx, depth: cint) {.importc, dynlib: DLLSSLName.}
proc verify_cb(preverify_ok: int, ctx: pointer): int{.cdecl.} = 1

proc i2d_X509(cert: PX509): string =
  ## encode `cert` to DER string
  let encoded_length = i2d_X509(cert, nil)
  result = newString(encoded_length)
  var q = result.cstring
  let o = cast[ptr ptr uint8](addr q)
  let length = i2d_X509(cert, o)
  if length.int < 0:
    raise newException(ValueError, "X.509 certificate encoding failed")

proc prepareGeminiCtx*(ctx: SslContext) =
  ctx.context.SSL_CTX_set_verify(SslVerifyPeer, verify_cb)
  ctx.context.SSL_CTX_set_verify_depth(0)
  
proc getX509Cert*(data: string): string =
  let
    bio = BIO_new_mem_buf(data.cstring, data.len.cint)
    x509 = bio.PEM_read_bio_X509(nil, 0, nil)
  bioFreeAll(bio)

  if x509 == nil: return
  return x509.i2d_X509

proc getPeerCertificate*(socket: AsyncSocket): string =
  let err = socket.sslHandle.SSL_get_verify_result()
  if err > 0 and err != X509_V_ERR_DEPTH_ZERO_SELF_SIGNED_CERT:
    raise newException(SSLError, "Certificate invalid or has expired")

  return socket.sslHandle.SSL_get_peer_certificate.i2d_X509


proc readAuthorised*(data: string): seq[string] =
  const
    beginSep = "-----BEGIN CERTIFICATE-----"
    endSep = "-----END CERTIFICATE-----"
  
  result = @[]
  var parseTop = 0
  while parseTop < data.len:
    let beginMark = data.find(beginSep, parseTop)
    if beginMark == -1: return
    let endMark = data.find(endSep, beginMark + beginSep.len)
    if endMark == -1: return

    result.add data[beginMark..endMark+endSep.len].getX509Cert()
    parseTop = endMark + endSep.len
