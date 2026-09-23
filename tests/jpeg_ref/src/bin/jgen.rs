// Test-corpus generator: jgen <in.rgb> <w> <h> <out.jpg> <quality> <sampling> <progressive 0|1> <restart> <gray 0|1>
use jpeg_encoder::{ColorType, Encoder, SamplingFactor};
fn main() {
    let a: Vec<String> = std::env::args().collect();
    let data = std::fs::read(&a[1]).unwrap();
    let (w, h): (u16, u16) = (a[2].parse().unwrap(), a[3].parse().unwrap());
    let mut enc = Encoder::new_file(&a[4], a[5].parse().unwrap()).unwrap();
    let sf = match a[6].as_str() {
        "11" => SamplingFactor::F_1_1, "21" => SamplingFactor::F_2_1, "12" => SamplingFactor::F_1_2,
        "22" => SamplingFactor::F_2_2, "41" => SamplingFactor::F_4_1, "42" => SamplingFactor::F_4_2,
        "14" => SamplingFactor::F_1_4, "24" => SamplingFactor::F_2_4, _ => panic!("sampling"),
    };
    enc.set_sampling_factor(sf);
    enc.set_progressive(a[7] == "1");
    let ri: u16 = a[8].parse().unwrap();
    if ri > 0 { enc.set_restart_interval(ri); }
    let ct = if a[9] == "1" { ColorType::Luma } else { ColorType::Rgb };
    enc.encode(&data, w, h, ct).unwrap();
}
