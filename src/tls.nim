import openssl, strutils, asyncdispatch
include asyncnet
export openssl

proc PEM_read_bio_X509(bio: BIO, x: PX509, password_cb: cint, u: pointer): PX509 {.importc, dynlib: DLLSSLName.}
proc SSL_get_verify_result(ssl: SslPtr): clong {.importc, dynlib: DLLSSLName.}
proc SSL_CTX_set_session_id_context*(ctx: SslCtx, id: string, idLen: int) {.importc, dynlib: DLLSSLName.}
proc SSL_CTX_set_verify*(ctx: SslCtx, mode: int, cb: proc(preverify_ok: int, ctx: PX509_STORE): int {.cdecl.}) {.importc, dynlib: DLLSSLName.}

proc sslSetSessionIdContext*(ctx: SslContext, id: string = "") =
  SSL_CTX_set_session_id_context(ctx.context, id, id.len)

proc verify_cb*(preverify_ok: int, ctx: PX509_STORE): int{.cdecl.} = 1

proc getCertString*(cert: PX509): string =
  if cert == nil: return
  return cert.i2d_X509

proc getX509Cert*(data: string): string =
  let
    bio = BIO_new_mem_buf(data.cstring, data.len.cint)
    x509 = bio.PEM_read_bio_X509(nil, 0, nil)
  bioFreeAll(bio)

  return getCertString(x509)

proc getPeerCertificate*(socket: AsyncSocket): string =
  let err = socket.sslHandle.SSL_get_verify_result()
  if err > 0 and err != X509_V_ERR_DEPTH_ZERO_SELF_SIGNED_CERT:
    raise newException(SSLError, "Certificate invalid or has expired")
  
  return socket.sslHandle.SSL_get_peer_certificate.getCertString()

proc parsePEM*(data: string): seq[string] =
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
