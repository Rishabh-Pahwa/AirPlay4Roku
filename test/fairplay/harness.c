/* Reference harness for the playfair FairPlay code in RPiPlay (built unmodified
 * from ../RPiPlay/lib by test/fairplay/run.sh).
 *
 *   harness gen N SEED   print random test lines: N "decrypt", N/4 "saphash", N/4 "md5",
 *                        4 "setup" and N/4 "handshake" (realistic FPLY headers)
 *   harness run          stdin lines "<op> <hex> [<hex>]", stdout "<op> <result hex>":
 *     decrypt <message3 164> <ekey 72>   playfair_decrypt keyOut
 *     setup <req 16>                     fairplay_setup reply (142) | invalid
 *     handshake <req 164>                fairplay_handshake reply (32) | invalid
 *     saphash <block 64>                 sap_hash keyOut
 *     md5 <block 64> <key 16>            modified_md5 keyOut
 *     sessionkey <message3 164>          generate_session_key(default_sap, message3)
 */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "fairplay.h"
#include "playfair/playfair.h"

void sap_hash(unsigned char *blockIn, unsigned char *keyOut);
void modified_md5(unsigned char *originalblockIn, unsigned char *keyIn, unsigned char *keyOut);
void generate_session_key(unsigned char *oldSap, unsigned char *messageIn, unsigned char *sessionKey);
extern unsigned char default_sap[];

static uint64_t rng;
static unsigned rnd8(void)
{
    rng ^= rng >> 12; rng ^= rng << 25; rng ^= rng >> 27;
    return (unsigned)((rng * 0x2545F4914F6CDD1DULL) >> 56);
}

static int unhex(const char *s, unsigned char *out, int n)
{
    for (int i = 0; i < n; i++) {
        unsigned v;
        if (sscanf(s + 2 * i, "%2x", &v) != 1) return -1;
        out[i] = (unsigned char)v;
    }
    return (int)strlen(s) == 2 * n ? 0 : -1;
}

static void puthex(const unsigned char *b, int n)
{
    for (int i = 0; i < n; i++) printf("%02x", b[i]);
}

int main(int argc, char **argv)
{
    char line[4096], a[2048], b[2048];
    const char *mode = argc > 1 ? argv[1] : "";

    if (!strcmp(mode, "gen")) {
        static const unsigned char mh[12] = {'F','P','L','Y',3,1,3,0,0,0,0,0x98};
        static const unsigned char eh[16] = {'F','P','L','Y',1,2,1,0,0,0,0,0x3c,0,0,0,0};
        int n = argc > 2 ? atoi(argv[2]) : 10;
        rng = (argc > 3 ? strtoull(argv[3], 0, 0) : 1) * 0x9E3779B97F4A7C15ULL + 1;
        for (int k = 0; k < n; k++) {
            unsigned char m[164], e[72];
            for (int i = 0; i < 164; i++) m[i] = i < 12 ? mh[i] : rnd8();
            m[12] = rnd8() & 3;   /* decryptMessage mode: message_key[mode], 0..3 only */
            for (int i = 0; i < 72; i++) e[i] = i < 16 ? eh[i] : rnd8();
            printf("decrypt "); puthex(m, 164); putchar(' '); puthex(e, 72); putchar('\n');
            if (k % 4 == 0) {
                printf("handshake "); puthex(m, 164); putchar('\n');
                printf("sessionkey "); puthex(m, 164); putchar('\n');
                for (int i = 0; i < 64; i++) e[i] = rnd8();
                printf("saphash "); puthex(e, 64); putchar('\n');
                for (int i = 0; i < 64; i++) e[i] = rnd8();
                printf("md5 "); puthex(e, 64); putchar(' ');
                for (int i = 0; i < 16; i++) printf("%02x", rnd8());
                putchar('\n');
            }
        }
        for (int k = 0; k < 4; k++) {
            unsigned char r[16] = {'F','P','L','Y',3,1,1,0,0,0,0,4,2,0,0,0xbb};
            r[14] = k;
            printf("setup "); puthex(r, 16); putchar('\n');
        }
        return 0;
    }

    fairplay_t *fp = fairplay_init(NULL);
    while (fgets(line, sizeof line, stdin)) {
        unsigned char m[164], e[72], out[142], blk[64], key[16];
        line[strcspn(line, "\r\n")] = 0;
        if (!line[0]) continue;
        char op[32] = "";
        a[0] = b[0] = 0;
        if (!strcmp(mode, "run")) sscanf(line, "%31s %2047s %2047s", op, a, b);
        else { strcpy(op, mode); sscanf(line, "%2047s %2047s", a, b); }
        printf("%s ", op);
        if (!strcmp(op, "decrypt")) {
            if (unhex(a, m, 164) || unhex(b, e, 72)) { puts("badinput"); continue; }
            playfair_decrypt(m, e, out);
            puthex(out, 16);
        } else if (!strcmp(op, "setup")) {
            if (unhex(a, m, 16)) { puts("badinput"); continue; }
            if (m[4] == 3 && m[14] > 3) { puts("undefined"); continue; } /* C reads out of bounds */
            if (fairplay_setup(fp, m, out) < 0) printf("invalid"); else puthex(out, 142);
        } else if (!strcmp(op, "handshake")) {
            if (unhex(a, m, 164)) { puts("badinput"); continue; }
            if (fairplay_handshake(fp, m, out) < 0) printf("invalid"); else puthex(out, 32);
        } else if (!strcmp(op, "saphash")) {
            if (unhex(a, blk, 64)) { puts("badinput"); continue; }
            sap_hash(blk, out);
            puthex(out, 16);
        } else if (!strcmp(op, "md5")) {
            if (unhex(a, blk, 64) || unhex(b, key, 16)) { puts("badinput"); continue; }
            modified_md5(blk, key, out);
            puthex(out, 16);
        } else if (!strcmp(op, "sessionkey")) {
            if (unhex(a, m, 164)) { puts("badinput"); continue; }
            generate_session_key(default_sap, m, out);
            puthex(out, 16);
        } else {
            fprintf(stderr, "unknown op '%s'\n", op);
            return 2;
        }
        putchar('\n');
    }
    fairplay_destroy(fp);
    return 0;
}
