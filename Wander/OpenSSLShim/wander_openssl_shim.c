// wander_openssl_shim.c — see wander_openssl_shim.h. Pure passthrough.

#include "wander_openssl_shim.h"

int wander_SSL_CTX_set_min_proto_version(SSL_CTX *ctx, int version) {
    return (int)SSL_CTX_set_min_proto_version(ctx, version);
}

int wander_SSL_CTX_set_max_proto_version(SSL_CTX *ctx, int version) {
    return (int)SSL_CTX_set_max_proto_version(ctx, version);
}

int wander_SSL_set_min_proto_version(SSL *ssl, int version) {
    return (int)SSL_set_min_proto_version(ssl, version);
}

int wander_SSL_set_max_proto_version(SSL *ssl, int version) {
    return (int)SSL_set_max_proto_version(ssl, version);
}

int wander_SSL_set_tlsext_host_name(SSL *ssl, const char *name) {
    // SSL_set_tlsext_host_name takes a non-const char*; OpenSSL copies the string.
    return (int)SSL_set_tlsext_host_name(ssl, (char *)name);
}

int wander_SSL_CTX_set_tlsext_servername_callback(SSL_CTX *ctx, int (*cb)(SSL *, int *, void *)) {
    return (int)SSL_CTX_set_tlsext_servername_callback(ctx, cb);
}

int wander_SSL_CTX_set_tlsext_servername_arg(SSL_CTX *ctx, void *arg) {
    return (int)SSL_CTX_set_tlsext_servername_arg(ctx, arg);
}

uint64_t wander_SSL_CTX_set_options(SSL_CTX *ctx, uint64_t options) {
    return SSL_CTX_set_options(ctx, options);
}

long wander_SSL_CTX_set_mode(SSL_CTX *ctx, long mode) {
    return SSL_CTX_set_mode(ctx, mode);
}

long wander_SSL_CTX_set_session_cache_mode(SSL_CTX *ctx, long mode) {
    return SSL_CTX_set_session_cache_mode(ctx, mode);
}

int wander_SSL_CTX_add_extra_chain_cert(SSL_CTX *ctx, X509 *x509) {
    return (int)SSL_CTX_add_extra_chain_cert(ctx, x509);
}

long wander_BIO_get_mem_data(BIO *bio, char **contents) {
    return BIO_get_mem_data(bio, contents);
}

const uint64_t wander_SSL_OP_NO_COMPRESSION = SSL_OP_NO_COMPRESSION;
const uint64_t wander_SSL_OP_NO_TICKET = SSL_OP_NO_TICKET;
const uint64_t wander_SSL_OP_CIPHER_SERVER_PREFERENCE = SSL_OP_CIPHER_SERVER_PREFERENCE;
