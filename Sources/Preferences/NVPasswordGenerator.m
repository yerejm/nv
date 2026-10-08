//
//  NVPasswordGenerator.h
//  Notation
//
//  Created by Brian Bergstrand on 9/27/2009.
//  Copyright 2009 Brian Bergstrand. All rights reserved.
//

#include "NVPasswordGenerator.h"

static const char nvDecimalSet[] = "0123456789";
static const char nvLowerCaseSet[] = "abcdefghijklmnopqrstuvwxyz";
static const char nvUpperCaseSet[] = "ABCDEFGHIJKLMNOPQRSTUVWXYZ";
static const char nvSymbolSet[] = "!@#$%^&*()-+=?/<>";

@implementation NVPasswordGenerator

+ (NSString*)passwordWithOptions:(NVPasswordOptions)options length:(NSUInteger)len
{
    char source[1024];
    source[0] = 0;
    
    if (0 != (options & knvPasswordNumeric))
        (void)strlcat(source, nvDecimalSet, sizeof(source));
    if (0 != (options & knvPasswordAlpha))
        (void)strlcat(source, nvLowerCaseSet, sizeof(source));
    if (0 != (options & knvPasswordMixedCase))
        (void)strlcat(source, nvUpperCaseSet, sizeof(source));
    if (0 != (options & knvPasswordSymbol))
        (void)strlcat(source, nvSymbolSet, sizeof(source));
    
    // Fill the buffer
    size_t i = strlen(source);
    size_t srclen = sizeof(source)-1 - i;
    (void)strlcpy(&source[i], source, srclen);
    
    char gen[len+1];
    gen[0] = 0;
    srclen = strlen(source);
    for (i = 0; i < len; ++i) {
        char c;
        do {
            c = source[arc4random_uniform((uint32_t)srclen)];
        } while (0 == (options & knvPasswordDuplicates) && NULL != strchr(gen, c));
        
        gen[i] = c;
        gen[i+1] = 0;
    }

    return ([NSString stringWithCString:gen encoding:NSASCIIStringEncoding]);
}

+ (NSString*)strong
{
    return ([self passwordWithOptions:knvPasswordNumeric|knvPasswordAlpha|knvPasswordMixedCase|knvPasswordSymbol length:10]);
}

@end
