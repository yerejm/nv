
#ifndef NV_MD5_H
#define NV_MD5_H

#include <stdint.h>

typedef unsigned char	nv_md5_byte;		// 1 nv_md5_byte = 8 bits  (unsigned)
typedef unsigned short	nv_md5_word16;		// 2 nv_md5_byte = 16 bits (unsigned)
typedef unsigned int	nv_md5_word32;		// 4 nv_md5_byte = 32 bits (unsigned)
typedef int		nv_md5_s_word32;	// 4 nv_md5_byte = 32 bits (signed)

struct NVMD5Context {
	nv_md5_word32 buf[4];
	nv_md5_word32 bits[2];
	unsigned char in[64];
};

void NVMD5Init(struct NVMD5Context *context);
void NVMD5Update(struct NVMD5Context *context, unsigned char const *buf,
	       unsigned len);
void NVMD5Final(nv_md5_byte digest[16], struct NVMD5Context *context);
void NVMD5Transform(nv_md5_word32 buf[4], nv_md5_word32 const in[16]);

/*
 * This is needed to make RSAREF happy on some MS-DOS compilers.
 */
typedef struct NVMD5Context NVMD5_CTX;

#endif /* !NV_MD5_H */
