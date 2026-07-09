#ifndef CICONV_H
#define CICONV_H

#include <iconv.h>
#include <stddef.h>
#include <stdlib.h>

/// Open a conversion descriptor
static inline iconv_t ci_iconv_open(const char *to, const char *from) {
    return iconv_open(to, from);
}

/// Perform conversion
static inline size_t ci_iconv(iconv_t cd, char **inbuf, size_t *inbytesleft,
                              char **outbuf, size_t *outbytesleft) {
    return iconv(cd, inbuf, inbytesleft, outbuf, outbytesleft);
}

/// Close conversion descriptor
static inline int ci_iconv_close(iconv_t cd) {
    return iconv_close(cd);
}

#endif /* CICONV_H */
