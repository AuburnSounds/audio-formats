 /**
 * Flake: FLAC audio encoder
 * Copyright (c) 2006 Justin Ruggles
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Lesser General Public
 * License as published by the Free Software Foundation; either
 * version 2 of the License, or (at your option) any later version.
 *
 * This library is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
 * Lesser General Public License for more details.
 *
 * You should have received a copy of the GNU Lesser General Public
 * License along with this library; if not, write to the Free Software
 * Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA
 */
/* public domain Simple, Minimalistic, FLAC encoder based on Flake
 * ©2018-2020 Yuichiro Nakada
 *
/*
    Copyright (c) 2026 Guillaume Piolat (D translation).
    To be clear, LGPL + public domain is still LGPL.

    Separated the hashes, since they come up in multiple formats.
*/
module audioformats.uflac_md5;

version(encodeFLAC):

import core.stdc.string: memcpy, memset;
nothrow @nogc:

alias int8_t   = byte;
alias uint8_t  = ubyte;
alias int16_t  = short;
alias uint16_t = ushort;
alias int32_t  = int;
alias uint32_t = uint;
alias int64_t  = long;
alias uint64_t = ulong;


// CRC

void crc_init_table(uint16_t *table, int bits, int poly)
{
    int i, j, crc;

    poly = (poly + (1<<bits));
    for (i=0; i<256; i++) {
        crc = i;
        for (j=0; j<bits; j++) {
            if (crc & (1<<(bits-1))) {
                crc = (crc << 1) ^ poly;
            } else {
                crc <<= 1;
            }
        }
        table[i] = cast(ushort)(crc & ((1<<bits)-1));
    }
}

// TODO: solution for this crap
// that would be like 1kb of tables.
static uint16_t[256] crc8tab;
static uint16_t[256] crc16tab;

void crc_init()
{
    /* CRC key for polynomial, x^8 + x^2 + x^1 + 1 */
    enum CRC8_POLY = 0x07;

    /* CRC key for polynomial, x^16 + x^15 + x^2 + 1 */
    enum CRC16_POLY = 0x8005;

    crc_init_table(crc8tab.ptr, 8, CRC8_POLY);
    crc_init_table(crc16tab.ptr, 16, CRC16_POLY);
}

uint16_t calc_crc(const uint16_t *table, int bits, const(uint8_t)* data, uint32_t len)
{
    uint16_t crc, v1, v2;

    crc = 0;
    while (len--) {
        v1 = cast(ushort)( (crc << 8) & ((1 << bits) - 1) );
        v2 = cast(ushort)( (crc >> (bits - 8)) ^ *data++ );
        assert(v2 < 256);
        crc = v1 ^ table[v2];
    }
    return crc;
}

uint8_t calc_crc8(const(uint8_t)*data, uint32_t len)
{
    uint8_t crc;

    if (data == null) {
        return 0;
    }

    crc = cast(ubyte) cast(ushort) calc_crc(crc8tab.ptr, 8, data, len);
    return crc;
}

uint16_t
calc_crc16(const uint8_t *data, uint32_t len)
{
    uint16_t crc;

    if (data == null) {
        return 0;
    }

    crc = cast(ushort) calc_crc(crc16tab.ptr, 16, data, len);
    return crc;
}

