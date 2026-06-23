//! Host-side smoke test: compile a .tex file to PDF via the library.
//!
//!   cargo run --example compile -- <input.tex> <out_dir>
use std::path::Path;
use std::process::exit;

fn main() {
    let args: Vec<String> = std::env::args().collect();
    if args.len() != 3 {
        eprintln!("usage: compile <input.tex> <out_dir>");
        exit(2);
    }
    match pdf_compiler::compile_file(Path::new(&args[1]), Path::new(&args[2])) {
        Ok(p) => {
            println!("OK -> {}", p.display());
        }
        Err(e) => {
            eprintln!("ERROR: {e}");
            exit(1);
        }
    }
}
