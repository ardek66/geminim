import strutils, parseutils

type
  Certificate* = string
  
  CertError* = enum
    CertOK
  
    CertExpired
    CertInvalid

  DigestType* = enum
    DigestErr
    DigestNull = "null"

    DigestMD5 = "md5"
    DigestSHA1 = "sha1"
    DigestSHA256 = "sha256"
    DigestSHA512 = "sha512"

  Authorisation* = tuple
    typ: DigestType
    digest: string

proc getPeerCertificate*(): Certificate =
  #[var cert = socket.sslHandle.SSL_get_peer_certificate()

  result = cert.i2d_x509
  X509_free(cert)]#
  return ""

proc getDigest*(cert: Certificate, typ: DigestType): string =
  #[
  let evp_typ = EVP_get_digestbyname(cstring($typ))
  result = newString(evp_typ.EVP_MD_size)
  
  var mdLen: cuint
  let err = EVP_Digest(cert.cstring, cert.len.cuint, result.cstring, addr mdLen, evp_typ)
  if(err < 1 or result.len != mdLen.int):
    raise newException(ValueError, "Digest failed.")

  return result.toHex()
]#

  return ""
