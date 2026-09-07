#include "include/tandem_tls.h"

#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <openssl/bio.h>
#include <openssl/err.h>
#include <openssl/pem.h>
#include <openssl/ssl.h>
#include <openssl/x509.h>

struct tandem_tls_ctx {
    SSL_CTX *ctx;
};

struct tandem_tls_conn {
    SSL *ssl;
};

static void copy_error(char *err, size_t err_len, const char *fallback)
{
    if (!err || err_len == 0) {
        return;
    }
    unsigned long code = ERR_get_error();
    if (code != 0) {
        char buffer[256];
        ERR_error_string_n(code, buffer, sizeof(buffer));
        snprintf(err, err_len, "%s", buffer);
    } else {
        snprintf(err, err_len, "%s", fallback ? fallback : "unknown OpenSSL error");
    }
    ERR_clear_error();
}

void tandem_tls_error_string(char *err, size_t err_len)
{
    copy_error(err, err_len, "no OpenSSL error queued");
}

tandem_tls_ctx *tandem_tls_ctx_new(const char *cert_pem, size_t cert_len,
                                   const char *key_pem, size_t key_len,
                                   char *err, size_t err_len)
{
    SSL_CTX *ctx = NULL;
    BIO *cert_bio = NULL;
    BIO *key_bio = NULL;
    X509 *cert = NULL;
    EVP_PKEY *key = NULL;
    struct tandem_tls_ctx *wrapper = NULL;

    ERR_clear_error();

    ctx = SSL_CTX_new(TLS_client_method());
    if (!ctx) {
        copy_error(err, err_len, "SSL_CTX_new failed");
        goto fail;
    }

    /* iOS 5+ speaks TLS 1.2; newer devices offer 1.3. */
    SSL_CTX_set_min_proto_version(ctx, TLS1_2_VERSION);
    SSL_CTX_set_max_proto_version(ctx, TLS1_3_VERSION);

    /* OpenSSL 3's default security level rejects both the device's key sizes
       and several of the suites lockdownd offers; pymobiledevice3 lowers it the
       same way via the "@SECLEVEL=0" cipher-string suffix. */
    SSL_CTX_set_security_level(ctx, 0);
    if (SSL_CTX_set_cipher_list(ctx, "ALL:!aNULL:!eNULL:@SECLEVEL=0") != 1) {
        copy_error(err, err_len, "SSL_CTX_set_cipher_list failed");
        goto fail;
    }

    /* Required by older lockdownd implementations that do not send the
       renegotiation info extension. */
    SSL_CTX_set_options(ctx, SSL_OP_LEGACY_SERVER_CONNECT);
    SSL_CTX_set_verify(ctx, SSL_VERIFY_NONE, NULL);

    cert_bio = BIO_new_mem_buf(cert_pem, (int)cert_len);
    if (!cert_bio) {
        copy_error(err, err_len, "BIO_new_mem_buf(cert) failed");
        goto fail;
    }
    cert = PEM_read_bio_X509(cert_bio, NULL, NULL, NULL);
    if (!cert) {
        copy_error(err, err_len, "HostCertificate is not readable PEM");
        goto fail;
    }
    if (SSL_CTX_use_certificate(ctx, cert) != 1) {
        copy_error(err, err_len, "SSL_CTX_use_certificate failed");
        goto fail;
    }

    key_bio = BIO_new_mem_buf(key_pem, (int)key_len);
    if (!key_bio) {
        copy_error(err, err_len, "BIO_new_mem_buf(key) failed");
        goto fail;
    }
    key = PEM_read_bio_PrivateKey(key_bio, NULL, NULL, NULL);
    if (!key) {
        copy_error(err, err_len, "HostPrivateKey is not readable PEM");
        goto fail;
    }
    if (SSL_CTX_use_PrivateKey(ctx, key) != 1) {
        copy_error(err, err_len, "SSL_CTX_use_PrivateKey failed");
        goto fail;
    }
    if (SSL_CTX_check_private_key(ctx) != 1) {
        copy_error(err, err_len, "HostCertificate and HostPrivateKey do not match");
        goto fail;
    }

    wrapper = (struct tandem_tls_ctx *)calloc(1, sizeof(struct tandem_tls_ctx));
    if (!wrapper) {
        copy_error(err, err_len, "out of memory");
        goto fail;
    }
    wrapper->ctx = ctx;
    ctx = NULL;

fail:
    if (cert) X509_free(cert);
    if (key) EVP_PKEY_free(key);
    if (cert_bio) BIO_free(cert_bio);
    if (key_bio) BIO_free(key_bio);
    if (ctx) SSL_CTX_free(ctx);
    return wrapper;
}

void tandem_tls_ctx_free(tandem_tls_ctx *ctx)
{
    if (!ctx) return;
    if (ctx->ctx) SSL_CTX_free(ctx->ctx);
    free(ctx);
}

tandem_tls_conn *tandem_tls_connect(tandem_tls_ctx *ctx, int fd,
                                    char *err, size_t err_len)
{
    if (!ctx || !ctx->ctx) {
        if (err && err_len) snprintf(err, err_len, "no TLS context");
        return NULL;
    }

    ERR_clear_error();

    SSL *ssl = SSL_new(ctx->ctx);
    if (!ssl) {
        copy_error(err, err_len, "SSL_new failed");
        return NULL;
    }
    /* No SNI: pymobiledevice3 passes server_hostname="" and the device does not
       care. Sending the IP as a hostname would be rejected anyway. */
    if (SSL_set_fd(ssl, fd) != 1) {
        copy_error(err, err_len, "SSL_set_fd failed");
        SSL_free(ssl);
        return NULL;
    }

    int rc = SSL_connect(ssl);
    if (rc != 1) {
        int reason = SSL_get_error(ssl, rc);
        char detail[256];
        detail[0] = '\0';
        if (reason == SSL_ERROR_SYSCALL) {
            snprintf(detail, sizeof(detail), "TLS handshake syscall error (errno %d: %s)",
                     errno, strerror(errno));
        } else if (reason == SSL_ERROR_ZERO_RETURN) {
            snprintf(detail, sizeof(detail), "device closed the connection during the TLS handshake");
        } else {
            snprintf(detail, sizeof(detail), "TLS handshake failed (SSL error %d)", reason);
        }
        copy_error(err, err_len, detail);
        SSL_free(ssl);
        return NULL;
    }

    struct tandem_tls_conn *conn = (struct tandem_tls_conn *)calloc(1, sizeof(struct tandem_tls_conn));
    if (!conn) {
        if (err && err_len) snprintf(err, err_len, "out of memory");
        SSL_free(ssl);
        return NULL;
    }
    conn->ssl = ssl;
    return conn;
}

long tandem_tls_read(tandem_tls_conn *conn, void *buf, int len, int *ssl_err)
{
    if (!conn || !conn->ssl) {
        if (ssl_err) *ssl_err = SSL_ERROR_SSL;
        return -1;
    }
    ERR_clear_error();
    int n = SSL_read(conn->ssl, buf, len);
    if (n > 0) {
        if (ssl_err) *ssl_err = SSL_ERROR_NONE;
        return (long)n;
    }
    int reason = SSL_get_error(conn->ssl, n);
    if (ssl_err) *ssl_err = reason;
    if (reason == SSL_ERROR_ZERO_RETURN) return 0;
    return -1;
}

long tandem_tls_write(tandem_tls_conn *conn, const void *buf, int len, int *ssl_err)
{
    if (!conn || !conn->ssl) {
        if (ssl_err) *ssl_err = SSL_ERROR_SSL;
        return -1;
    }
    ERR_clear_error();
    int n = SSL_write(conn->ssl, buf, len);
    if (n > 0) {
        if (ssl_err) *ssl_err = SSL_ERROR_NONE;
        return (long)n;
    }
    int reason = SSL_get_error(conn->ssl, n);
    if (ssl_err) *ssl_err = reason;
    if (reason == SSL_ERROR_ZERO_RETURN) return 0;
    return -1;
}

void tandem_tls_close(tandem_tls_conn *conn)
{
    if (!conn) return;
    if (conn->ssl) {
        SSL_shutdown(conn->ssl);
        SSL_free(conn->ssl);
    }
    free(conn);
}
