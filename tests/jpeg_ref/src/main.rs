// Reference: exactly resvg 0.48.1's decode_jpeg (crates/resvg/src/image.rs).
// usage: jref <in.jpg> <out.rgba> [safe]   prints "w h" or "NONE"
use std::io::Cursor;
use zune_jpeg::zune_core::colorspace::ColorSpace;
use zune_jpeg::zune_core::options::DecoderOptions;

fn decode(data: &[u8], safe: bool) -> Option<(usize, usize, Vec<u8>)> {
    let base = if safe { DecoderOptions::new_safe() } else { DecoderOptions::default() };
    let options = base.jpeg_set_out_colorspace(ColorSpace::RGBA);
    let mut decoder = zune_jpeg::JpegDecoder::new_with_options(Cursor::new(data), options);
    decoder.decode_headers().ok()?;
    let output_cs = decoder.output_colorspace()?;
    let img = decoder.decode().ok()?;
    if output_cs != ColorSpace::RGBA { return None; }
    let info = decoder.info()?;
    if info.width == 0 || info.height == 0 { return None; }
    Some((info.width as usize, info.height as usize, img))
}

fn main() {
    let a: Vec<String> = std::env::args().collect();
    let data = std::fs::read(&a[1]).unwrap();
    let safe = a.len() > 3 && a[3] == "safe";
    match decode(&data, safe) {
        Some((w, h, px)) => { assert_eq!(px.len(), w * h * 4); std::fs::write(&a[2], &px).unwrap(); println!("{w} {h}"); }
        None => println!("NONE"),
    }
}
