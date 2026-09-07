#ifndef TANDEM_TLS_H
#define TANDEM_TLS_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/*
 * A very small OpenSSL wrapper, existing only because most of what we need from
 * <openssl/ssl.h> (SSL_CTX_set_min_proto_version, SSL_CTX_set_options, ...) is
 * a macro over SSL_CTX_ctrl and therefore invisible to Swift.
 *
 * The TLS parameters here are copied from pymobiledevice3's
 * ServiceConnection.create_ssl_context(): lockdownd on iOS negotiates cipher
 * suites that OpenSSL 3 rejects at its default security level, so the level is
 * dropped to 0 and SSL_OP_LEGACY_SERVER_CONNECT is set. The peer certificate is
 * deliberately not verified — the device presents a self-signed certificate and
 * mutual trust comes from the client certificate out of the pair record.
 */

typedef struct tandem_tls_ctx tandem_tls_ctx;
typedef struct tandem_tls_conn tandem_tls_conn;

/* Build a client context from PEM held in memory. Nothing is written to disk.
   Returns NULL on failure, with a description in `err`. */
tandem_tls_ctx *tandem_tls_ctx_new(const char *cert_pem, size_t cert_len,
                                   const char *key_pem, size_t key_len,
                                   char *err, size_t err_len);

void tandem_tls_ctx_free(tandem_tls_ctx *ctx);

/* Handshake as a client over an already-connected, blocking socket. The socket
   keeps whatever SO_RCVTIMEO/SO_SNDTIMEO the caller set, which is what bounds
   the handshake. On failure returns NULL and `fd` is left untouched (the caller
   still owns and must close it). */
tandem_tls_conn *tandem_tls_connect(tandem_tls_ctx *ctx, int fd,
                                    char *err, size_t err_len);

/* Both return the byte count, 0 on clean EOF, or -1 on error; `ssl_err`
   receives SSL_get_error(). */
long tandem_tls_read(tandem_tls_conn *conn, void *buf, int len, int *ssl_err);
long tandem_tls_write(tandem_tls_conn *conn, const void *buf, int len, int *ssl_err);

/* Sends close_notify (best effort) and frees the SSL. Does not close the fd. */
void tandem_tls_close(tandem_tls_conn *conn);

/* Human-readable text for the most recent OpenSSL error on this thread. */
void tandem_tls_error_string(char *err, size_t err_len);

#ifdef __cplusplus
}
#endif

#endif
