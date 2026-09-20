// wander_openssl_shim.h
// Thin C wrappers for OpenSSL entry points that are preprocessor macros and are
// therefore invisible to the Swift clang importer. Everything here is a 1:1
// passthrough — no policy, no allocation, no state.
//
// Only wrap things that are actually macros. Most of OpenSSL 3.3 imports fine
// already (SSL_CTX_new, SSL_ctrl, X509_sign, X509_getm_notBefore, X509_gmtime_adj,
// EVP_PKEY_set1_EC_KEY, X509V3_EXT_conf_nid, PKCS12_create, ...). Call those directly.

#ifndef WANDER_OPENSSL_SHIM_H
#define WANDER_OPENSSL_SHIM_H

#include <stdint.h>
#include <OpenSSL/ssl.h>
#include <OpenSSL/bio.h>
#include <OpenSSL/x509.h>

#ifdef __cplusplus
extern "C" {
#endif

// --- protocol version bounds (macros over SSL_CTX_ctrl / SSL_ctrl) ---
int wander_SSL_CTX_set_min_proto_version(SSL_CTX *ctx, int version);
int wander_SSL_CTX_set_max_proto_version(SSL_CTX *ctx, int version);
int wander_SSL_set_min_proto_version(SSL *ssl, int version);
int wander_SSL_set_max_proto_version(SSL *ssl, int version);

// --- SNI on the outbound leg (macro over SSL_ctrl) ---
int wander_SSL_set_tlsext_host_name(SSL *ssl, const char *name);

// --- SNI dispatch on the inbound (server) leg (macros over SSL_CTX_callback_ctrl/ctrl) ---
int wander_SSL_CTX_set_tlsext_servername_callback(SSL_CTX *ctx, int (*cb)(SSL *, int *, void *));
int wander_SSL_CTX_set_tlsext_servername_arg(SSL_CTX *ctx, void *arg);

// --- context flags (set_options is a real fn in 3.x; wrapped for a stable signature) ---
uint64_t wander_SSL_CTX_set_options(SSL_CTX *ctx, uint64_t options);
long wander_SSL_CTX_set_mode(SSL_CTX *ctx, long mode);
long wander_SSL_CTX_set_session_cache_mode(SSL_CTX *ctx, long mode);

// --- serving the leaf's issuing chain (macro over SSL_CTX_ctrl) ---
int wander_SSL_CTX_add_extra_chain_cert(SSL_CTX *ctx, X509 *x509);

// --- read a memory BIO without copying (macro over BIO_ctrl) ---
long wander_BIO_get_mem_data(BIO *bio, char **contents);

// --- SSL_OP_* built with the function-like macro SSL_OP_BIT(n), so they do not import ---
extern const uint64_t wander_SSL_OP_NO_COMPRESSION;
extern const uint64_t wander_SSL_OP_NO_TICKET;
extern const uint64_t wander_SSL_OP_CIPHER_SERVER_PREFERENCE;

#ifdef __cplusplus
}
#endif

#endif /* WANDER_OPENSSL_SHIM_H */
