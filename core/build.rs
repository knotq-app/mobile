fn main() {
    uniffi::generate_scaffolding("src/knotq_mobile_core.udl").expect("generate UniFFI scaffolding");
}
