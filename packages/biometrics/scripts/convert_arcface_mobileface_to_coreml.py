#!/usr/bin/env python3
from __future__ import annotations

import argparse
import shutil
import subprocess
from pathlib import Path

import coremltools as ct
import torch
from onnx2torch import convert


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Convert an ArcFace MobileFace ONNX checkpoint into a Core ML package and, "
            "optionally, a compiled .mlmodelc bundle for iPhone demos."
        )
    )
    parser.add_argument("--onnx-path", required=True, help="Path to the source ONNX model.")
    parser.add_argument("--mlpackage-path", required=True, help="Path to the output .mlpackage.")
    parser.add_argument(
        "--compiled-output-dir",
        help="Optional directory where xcrun coremlcompiler should emit the compiled .mlmodelc bundle.",
    )
    parser.add_argument(
        "--input-shape",
        default="1,3,112,112",
        help="Model input shape in N,C,H,W format. Default: 1,3,112,112",
    )
    return parser.parse_args()


def parse_input_shape(value: str) -> tuple[int, int, int, int]:
    parts = tuple(int(piece.strip()) for piece in value.split(","))
    if len(parts) != 4:
        raise ValueError("Expected --input-shape in N,C,H,W format.")
    return parts


def compile_model(mlpackage_path: Path, compiled_output_dir: Path) -> Path:
    compiled_output_dir.mkdir(parents=True, exist_ok=True)
    subprocess.run(
        [
            "xcrun",
            "coremlcompiler",
            "compile",
            str(mlpackage_path),
            str(compiled_output_dir),
        ],
        check=True,
    )
    return compiled_output_dir / f"{mlpackage_path.stem}.mlmodelc"


def main() -> None:
    args = parse_args()
    onnx_path = Path(args.onnx_path).expanduser().resolve()
    mlpackage_path = Path(args.mlpackage_path).expanduser().resolve()
    input_shape = parse_input_shape(args.input_shape)

    if onnx_path.exists() is False:
        raise FileNotFoundError(f"ONNX model not found: {onnx_path}")

    torch_model = convert(str(onnx_path))
    torch_model.eval()

    example_input = torch.randn(*input_shape)
    traced_model = torch.jit.trace(torch_model, example_input)

    mlmodel = ct.convert(
        traced_model,
        inputs=[ct.TensorType(name="input", shape=input_shape)],
        convert_to="mlprogram",
        minimum_deployment_target=ct.target.iOS17,
    )
    mlpackage_path.parent.mkdir(parents=True, exist_ok=True)
    if mlpackage_path.exists():
        shutil.rmtree(mlpackage_path)
    mlmodel.save(str(mlpackage_path))

    if args.compiled_output_dir:
        compiled_dir = Path(args.compiled_output_dir).expanduser().resolve()
        modelc_path = compile_model(mlpackage_path=mlpackage_path, compiled_output_dir=compiled_dir)
        print(f"Compiled Core ML bundle: {modelc_path}")

    print(f"Saved Core ML package: {mlpackage_path}")


if __name__ == "__main__":
    main()
