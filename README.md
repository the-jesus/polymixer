# Polyglot File Generator

## Overview
The Polyglot File Generator is a modular, Python-based tool designed to combine multiple files into a single polyglot file. This tool supports various modules such as ZIP, TrueCrypt, and random data inclusion, allowing for complex file structures and custom use cases. It's particularly useful for creating files that can function in multiple contexts, e.g., as both a ZIP archive and a TrueCrypt container.

## Prerequisites
- Python 3.x
- Necessary Python libraries installed from the requirements.txt file.

## Installation
Clone the repository to your local machine:
```bash
git clone ...
cd ...
```

Install the required Python libraries:
```bash
pip install -r requirements.txt
```

## Usage
To use the Polyglot File Generator, run the main script with the desired parameters:
```bash
python main.py --output output.zip --modules zip truecrypt random --zip-file=samples/ttt.zip --shell-file=samples/test.sh --truecrypt-file=samples/container.ts
```

### Parameters
- `--output`: Specifies the name of the output file.
- `--modules`: A list of modules to apply in the creation process.
- Module-specific files:
  - `--zip-file`: The ZIP file to include.
  - `--shell-file`: The shell script file to include.
  - `--truecrypt-file`: The TrueCrypt container to include.

## Modules
Modules are located under the `modules/` directory and can be specified in the command line. Each module handles a specific type of file and can be independently configured.

## Tools
Two utility tools are included for debugging and validation:
- `check-zip.sh`: Displays debugging information about ZIP files.
- `zip-parser.py`: Tests if the ZIP file has been generated with errors.

These tools are located in the `tools/` directory.

## Samples
Sample files that can be used with the Polyglot File Generator are located under the `samples/` directory. These include various formats that demonstrate the capabilities of the tool.
