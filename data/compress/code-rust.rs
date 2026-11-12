use crate::iter::Bytes;

#[inline]
#[target_feature(enable = "avx2")]
pub unsafe fn match_uri_vectored(bytes: &mut Bytes) {
    while bytes.as_ref().len() >= 32 {

        let advance = match_url_char_32_avx(bytes.as_ref());

        bytes.advance(advance);

        if advance != 32 {
            return;
        }
    }
    // NOTE: use SWAR for <32B, more efficient than falling back to SSE4.2
    super::swar::match_uri_vectored(bytes)
}

#[inline(always)]
#[allow(non_snake_case, overflowing_literals)]
#[allow(unused)]
unsafe fn match_url_char_32_avx(buf: &[u8]) -> usize {
    // NOTE: This check might be not necessary since this function is only used in
    // `match_uri_vectored` where buffer overflow is taken care of.
    debug_assert!(buf.len() >= 32);

    #[cfg(target_arch = "x86")]
    use core::arch::x86::*;
    #[cfg(target_arch = "x86_64")]
    use core::arch::x86_64::*;

    // pointer to buffer
    let ptr = buf.as_ptr();

    // %x21-%x7e %x80-%xff
    //
    // Character ranges allowed by this function, can also be interpreted as:
    // 33 =< (x != 127) =< 255
    //
    // Create a vector full of DEL (0x7f) characters.
    let DEL: __m256i = _mm256_set1_epi8(0x7f);
    // Create a vector full of exclamation mark (!) (0x21) characters.
    // Used as lower threshold, characters in URLs cannot be smaller than this.
    let LOW: __m256i = _mm256_set1_epi8(0x21);

    // Load a chunk of 32 bytes from `ptr` as a vector.
    // We can check 32 bytes in parallel at most with AVX2 since
    // YMM registers can only have 256 bits most.
    let dat = _mm256_lddqu_si256(ptr as *const _);

    // unsigned comparison dat >= LOW
    //
    // `_mm256_max_epu8` creates a new vector by comparing vectors `dat` and `LOW`
    // and picks the max. values from each for all indices.
    // So if a byte in `dat` is <= 32, it'll be represented as 33
    // which is the smallest valid character.
    //
    // Then, we compare the new vector with `dat` for equality.
    //
    // `_mm256_cmpeq_epi8` returns a new vector where;
    // * matching bytes are set to 0xFF (all bits set),
    // * nonmatching bytes are set to 0 (no bits set).
    let low = _mm256_cmpeq_epi8(_mm256_max_epu8(dat, LOW), dat);
    // Similar to what we did before, but now invalid characters are set to 0xFF.
    let del = _mm256_cmpeq_epi8(dat, DEL);

    // We glue the both comparisons via `_mm256_andnot_si256`.
    //
    // Since the representation of truthiness differ in these comparisons,
    // we are in need of bitwise NOT to convert valid characters of `del`.
    let bit = _mm256_andnot_si256(del, low);
    // This creates a bitmask from the most significant bit of each byte.
    // Simply, we're converting a vector value to scalar value here.
    let res = _mm256_movemask_epi8(bit) as u32;

    // Count trailing ones to find the first encountered invalid character.
    res.trailing_ones() as usize
}

#[target_feature(enable = "avx2")]
pub unsafe fn match_header_value_vectored(bytes: &mut Bytes) {
    while bytes.as_ref().len() >= 32 {
        let advance = match_header_value_char_32_avx(bytes.as_ref());
        bytes.advance(advance);

        if advance != 32 {
            return;
        }
    }
    // NOTE: use SWAR for <32B, more efficient than falling back to SSE4.2
    super::swar::match_header_value_vectored(bytes)
}

#[inline(always)]
#[allow(non_snake_case)]
#[allow(unused)]
unsafe fn match_header_value_char_32_avx(buf: &[u8]) -> usize {
    debug_assert!(buf.len() >= 32);

    #[cfg(target_arch = "x86")]
    use core::arch::x86::*;
    #[cfg(target_arch = "x86_64")]
    use core::arch::x86_64::*;

    let ptr = buf.as_ptr();

    // %x09 %x20-%x7e %x80-%xff
    // Create a vector full of horizontal tab (\t) (0x09) characters.
    let TAB: __m256i = _mm256_set1_epi8(0x09);
    // Create a vector full of DEL (0x7f) characters.
    let DEL: __m256i = _mm256_set1_epi8(0x7f);
    // Create a vector full of space (0x20) characters.
    let LOW: __m256i = _mm256_set1_epi8(0x20);

    // Load a chunk of 32 bytes from `ptr` as a vector.
    let dat = _mm256_lddqu_si256(ptr as *const _);

    // unsigned comparison dat >= LOW
    //
    // Same as what we do in `match_url_char_32_avx`.
    // This time the lower threshold is set to space character though.
    let low = _mm256_cmpeq_epi8(_mm256_max_epu8(dat, LOW), dat);
    // Check if `dat` includes `TAB` characters.
    let tab = _mm256_cmpeq_epi8(dat, TAB);
    // Check if `dat` includes `DEL` characters.
    let del = _mm256_cmpeq_epi8(dat, DEL);

    // Combine all comparisons together, notice that we're also using OR
    // to connect `low` and `tab` but flip bits of `del`.
    //
    // In the end, this is simply:
    // ~del & (low | tab)
    let bit = _mm256_andnot_si256(del, _mm256_or_si256(low, tab));
    // This creates a bitmask from the most significant bit of each byte.
    // Creates a scalar value from vector value.
    let res = _mm256_movemask_epi8(bit) as u32;

    // Count trailing ones to find the first encountered invalid character.
    res.trailing_ones() as usize
}

#[test]
fn avx2_code_matches_uri_chars_table() {
    if !is_x86_feature_detected!("avx2") {
        return;
    }

    #[allow(clippy::undocumented_unsafe_blocks)]
    unsafe {
        assert!(byte_is_allowed(b'_', match_uri_vectored));

        for (b, allowed) in crate::URI_MAP.iter().cloned().enumerate() {
            assert_eq!(
                byte_is_allowed(b as u8, match_uri_vectored), allowed,
                "byte_is_allowed({:?}) should be {:?}", b, allowed,
            );
        }
    }
}

#[test]
fn avx2_code_matches_header_value_chars_table() {
    if !is_x86_feature_detected!("avx2") {
        return;
    }

    #[allow(clippy::undocumented_unsafe_blocks)]
    unsafe {
        assert!(byte_is_allowed(b'_', match_header_value_vectored));

        for (b, allowed) in crate::HEADER_VALUE_MAP.iter().cloned().enumerate() {
            assert_eq!(
                byte_is_allowed(b as u8, match_header_value_vectored), allowed,
                "byte_is_allowed({:?}) should be {:?}", b, allowed,
            );
        }
    }
}

#[cfg(test)]
unsafe fn byte_is_allowed(byte: u8, f: unsafe fn(bytes: &mut Bytes<'_>)) -> bool {
    let slice = [
        b'_', b'_', b'_', b'_',
        b'_', b'_', b'_', b'_',
        b'_', b'_', b'_', b'_',
        b'_', b'_', b'_', b'_',
        b'_', b'_', b'_', b'_',
        b'_', b'_', b'_', b'_',
        b'_', b'_', byte, b'_',
        b'_', b'_', b'_', b'_',
    ];
    let mut bytes = Bytes::new(&slice);

    f(&mut bytes);

    match bytes.pos() {
        32 => true,
        26 => false,
        _ => unreachable!(),
    }
}
mod swar;

#[cfg(any(
    httparse_disable_simd,
    miri,
    not(any(
        target_arch = "x86",
        target_arch = "x86_64",
        all(
            target_arch = "aarch64",
            target_feature = "neon",
        )
    )),
    all(
        not(feature = "std"),
        not(any(
            target_feature = "sse4.2",
            target_feature = "avx2",
        )),
        any(
            target_arch = "x86",
            target_arch = "x86_64",
        ),
    )
))]
pub use self::swar::*;

#[cfg(all(
    not(any(httparse_disable_simd, miri)),
    any(
        feature = "std",
        target_feature = "sse4.2",
    ),
    not(target_feature = "avx2"),
    any(
        target_arch = "x86",
        target_arch = "x86_64",
    ),
))]
mod sse42;

#[cfg(all(
    not(any(httparse_disable_simd, miri)),
    any(
        target_feature = "avx2",
        all(
            feature = "std",
            not(target_feature = "sse4.2"),
        ),
    ),
    any(
        target_arch = "x86",
        target_arch = "x86_64",
    ),
))]
mod avx2;

#[cfg(all(
    not(any(httparse_disable_simd, miri)),
    feature = "std",
    not(any(
        target_feature = "sse4.2",
        target_feature = "avx2",
    )),
    any(
        target_arch = "x86",
        target_arch = "x86_64",
    ),
))]
mod runtime;

#[cfg(all(
    not(any(httparse_disable_simd, miri)),
    feature = "std",
    not(any(
        target_feature = "sse4.2",
        target_feature = "avx2",
    )),
    any(
        target_arch = "x86",
        target_arch = "x86_64",
    ),
))]
pub use self::runtime::*;

#[cfg(all(
    not(any(httparse_disable_simd, miri)),
    target_feature = "sse4.2",
    not(target_feature = "avx2"),
    any(
        target_arch = "x86",
        target_arch = "x86_64",
    ),
))]
mod sse42_compile_time {
    #[inline(always)]
    pub fn match_header_name_vectored(b: &mut crate::iter::Bytes<'_>) {
        super::swar::match_header_name_vectored(b);
    }

    #[inline(always)]
    pub fn match_uri_vectored(b: &mut crate::iter::Bytes<'_>) {
        unsafe { super::sse42::match_uri_vectored(b) }
    }

    #[inline(always)]
    pub fn match_header_value_vectored(b: &mut crate::iter::Bytes<'_>) {
        unsafe { super::sse42::match_header_value_vectored(b) }
    }
}

#[cfg(all(
    not(any(httparse_disable_simd, miri)),
    target_feature = "sse4.2",
    not(target_feature = "avx2"),
    any(
        target_arch = "x86",
        target_arch = "x86_64",
    ),
))]
pub use self::sse42_compile_time::*;

#[cfg(all(
    not(any(httparse_disable_simd, miri)),
    target_feature = "avx2",
    any(
        target_arch = "x86",
        target_arch = "x86_64",
    ),
))]
mod avx2_compile_time {
    #[inline(always)]
    pub fn match_header_name_vectored(b: &mut crate::iter::Bytes<'_>) {
        super::swar::match_header_name_vectored(b);
    }

    #[inline(always)]
    pub fn match_uri_vectored(b: &mut crate::iter::Bytes<'_>) {
        unsafe { super::avx2::match_uri_vectored(b) }
    }

    #[inline(always)]
    pub fn match_header_value_vectored(b: &mut crate::iter::Bytes<'_>) {
        unsafe { super::avx2::match_header_value_vectored(b) }
    }
}

#[cfg(all(
    not(any(httparse_disable_simd, miri)),
    target_feature = "avx2",
    any(
        target_arch = "x86",
        target_arch = "x86_64",
    ),
))]
pub use self::avx2_compile_time::*;

#[cfg(all(
    not(any(httparse_disable_simd, miri)),
    target_arch = "aarch64",
    target_feature = "neon",
))]
mod neon;

#[cfg(all(
    not(any(httparse_disable_simd, miri)),
    target_arch = "aarch64",
    target_feature = "neon",
))]
pub use self::neon::*;
use crate::iter::Bytes;
use core::arch::aarch64::*;

#[inline]
pub fn match_header_name_vectored(bytes: &mut Bytes) {
    while bytes.as_ref().len() >= 16 {
        // SAFETY: ensured that there are at least 16 bytes remaining 
        unsafe {
            let advance = match_header_name_char_16_neon(bytes.as_ref().as_ptr());
            bytes.advance(advance);

            if advance != 16 {
                return;
            }
        }
    }
    super::swar::match_header_name_vectored(bytes);
}

#[inline]
pub fn match_header_value_vectored(bytes: &mut Bytes) {
    while bytes.as_ref().len() >= 16 {
        // SAFETY: ensured that there are at least 16 bytes remaining 
        unsafe {
            let advance = match_header_value_char_16_neon(bytes.as_ref().as_ptr());
            bytes.advance(advance);

            if advance != 16 {
                return;
            }
        }
    }
    super::swar::match_header_value_vectored(bytes);
}

#[inline]
pub fn match_uri_vectored(bytes: &mut Bytes) {
    while bytes.as_ref().len() >= 16 {
        // SAFETY: ensured that there are at least 16 bytes remaining 
        unsafe {
            let advance = match_url_char_16_neon(bytes.as_ref().as_ptr());
            bytes.advance(advance);

            if advance != 16 {
                return;
            }
        }
    }
    super::swar::match_uri_vectored(bytes);
}

const fn bit_set(x: u8) -> bool {
    // Validates if a byte is a valid header name character
    // https://tools.ietf.org/html/rfc7230#section-3.2.6
    matches!(x, b'0'..=b'9' | b'a'..=b'z' | b'A'..=b'Z' | b'!' | b'#' | b'$' | b'%' | b'&' | b'\'' | b'*' | b'+' | b'-' | b'.' | b'^' | b'_' | b'`' | b'|' | b'~')
}

// A 256-bit bitmap, split into two halves
// lower half contains bits whose higher nibble is <= 7
// higher half contains bits whose higher nibble is >= 8
const fn build_bitmap() -> ([u8; 16], [u8; 16]) {
    let mut bitmap_0_7 = [0u8; 16]; // 0x00..0x7F
    let mut bitmap_8_15 = [0u8; 16]; // 0x80..0xFF
    let mut i = 0;
    while i < 256 {
        if bit_set(i as u8) {
            // Nibbles
            let (lo, hi) = (i & 0x0F, i >> 4);
            if i < 128 {
                bitmap_0_7[lo] |= 1 << hi;
            } else {
                bitmap_8_15[lo] |= 1 << hi;
            }
        }
        i += 1;
    }
    (bitmap_0_7, bitmap_8_15)
}

const BITMAPS: ([u8; 16], [u8; 16]) = build_bitmap();

// NOTE: adapted from 256-bit version, with upper 128-bit ops commented out
#[inline]
unsafe fn match_header_name_char_16_neon(ptr: *const u8) -> usize {
    let bitmaps = BITMAPS;
    // NOTE: ideally compile-time constants
    let (bitmap_0_7, _bitmap_8_15) = bitmaps;
    let bitmap_0_7 = vld1q_u8(bitmap_0_7.as_ptr());
    // let bitmap_8_15 = vld1q_u8(bitmap_8_15.as_ptr());

    // Initialize the bitmask_lookup.
    const BITMASK_LOOKUP_DATA: [u8; 16] =
        [1, 2, 4, 8, 16, 32, 64, 128, 1, 2, 4, 8, 16, 32, 64, 128];
    let bitmask_lookup = vld1q_u8(BITMASK_LOOKUP_DATA.as_ptr());

    // Load 16 input bytes.
    let input = vld1q_u8(ptr);

    // Extract indices for row_0_7.
    let indices_0_7 = vandq_u8(input, vdupq_n_u8(0x8F)); // 0b1000_1111;

    // Extract indices for row_8_15.
    // let msb = vandq_u8(input, vdupq_n_u8(0x80));
    // let indices_8_15 = veorq_u8(indices_0_7, msb);

    // Fetch row_0_7 and row_8_15.
    let row_0_7 = vqtbl1q_u8(bitmap_0_7, indices_0_7);
    // let row_8_15 = vqtbl1q_u8(bitmap_8_15, indices_8_15);

    // Calculate a bitmask, i.e. (1 << hi_nibble % 8).
    let bitmask = vqtbl1q_u8(bitmask_lookup, vshrq_n_u8(input, 4));

    // Choose rows halves depending on higher nibbles.
    // let bitsets = vorrq_u8(row_0_7, row_8_15);
    let bitsets = row_0_7;

    // Finally check which bytes belong to the set.
    let tmp = vandq_u8(bitsets, bitmask);
    let result = vceqq_u8(tmp, bitmask);

    offsetz(result) as usize
}

#[inline]
unsafe fn match_url_char_16_neon(ptr: *const u8) -> usize {
    let input = vld1q_u8(ptr);

    // Check that b'!' <= and b != 127
    let result = vcleq_u8(vdupq_n_u8(b'!'), input);

    // Disallow del
    let del = vceqq_u8(input, vdupq_n_u8(0x7F));
    let result = vbicq_u8(result, del);

    offsetz(result) as usize
}

#[inline]
unsafe fn match_header_value_char_16_neon(ptr: *const u8) -> usize {
    let input = vld1q_u8(ptr);

    // Check that b' ' <= and b != 127 or b == 9
    let result = vcleq_u8(vdupq_n_u8(b' '), input);

    // Allow tab
    let tab = vceqq_u8(input, vdupq_n_u8(0x09));
    let result = vorrq_u8(result, tab);

    // Disallow del
    let del = vceqq_u8(input, vdupq_n_u8(0x7F));
    let result = vbicq_u8(re