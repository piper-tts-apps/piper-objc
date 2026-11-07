// Command-line front end for piper-objc.
//
// Synthesizes text to a .wav file with the same engine the Piper app uses,
// which is handy for reproducing app behaviour outside the app, comparing
// renders, and debugging a voice.
//
// Usage:
//   piper-cli --model <model.onnx> --config <model.onnx.json> --output <out.wav> <text>
//   piper-cli --model <model.onnx> --config <model.onnx.json> --output <out.wav> --text-file <file>
//   piper-cli --model <model.onnx> --config <model.onnx.json> --output <out.wav> --stdin
//
// Options:
//   --model <path>       Path to the .onnx voice model (required).
//   --config <path>      Path to the model's .onnx.json config (required).
//   --output <path>      Path of the .wav file to write (required).
//   --espeak-data <dir>  Path to espeak-ng-data. If omitted, the bundled
//                        espeak data is used (see Piper.ensureEspeakLibDataInstalled).
//   --text-file <path>   Read the text from a file instead of the command line.
//   --stdin              Read the text from stdin instead of the command line.
//   --ssml               Treat the text as SSML instead of plain text.
//   --speaker-id <n>     Speaker id for SSML/multi-speaker models (default 0).
//   --help, -h           Show this help.
//
// Text comes from exactly one of: positional arguments, --text-file, --stdin.

import Foundation
import piper_objc

private let usage = """
Usage: piper-cli --model <model.onnx> --config <model.onnx.json> --output <out.wav> [--espeak-data <dir>] [--text-file <file> | --stdin | <text...>]

Options:
  --model <path>       Path to the .onnx voice model (required).
  --config <path>      Path to the model's .onnx.json config (required).
  --output <path>      Path of the .wav file to write (required).
  --espeak-data <dir>  Path to espeak-ng-data (default: bundled data).
  --text-file <path>   Read the text from a file.
  --stdin              Read the text from stdin.
  --ssml               Treat the text as SSML instead of plain text.
  --speaker-id <n>     Speaker id for SSML/multi-speaker models (default 0).
  --help, -h           Show this help.
"""

private struct Options {
    var model: String
    var config: String
    var output: String
    var espeakData: String?
    var text: String
    var isSSML: Bool
    var speakerId: Int32
}

private func fail(_ message: String, showUsage: Bool = false) -> Never {
    fputs("piper-cli: \(message)\n", stderr)
    if showUsage {
        fputs("\n\(usage)\n", stderr)
    }
    exit(2)
}

private func parse(_ arguments: [String]) -> Options {
    var model: String?
    var config: String?
    var output: String?
    var espeakData: String?
    var textFile: String?
    var useStdin = false
    var isSSML = false
    var speakerId: Int32 = 0
    var positional: [String] = []

    var i = 0
    while i < arguments.count {
        let arg = arguments[i]
        func value(for flag: String) -> String {
            guard i + 1 < arguments.count else {
                fail("missing value for \(flag)", showUsage: true)
            }
            i += 1
            return arguments[i]
        }
        switch arg {
        case "--help", "-h":
            print(usage)
            exit(0)
        case "--model":
            model = value(for: arg)
        case "--config":
            config = value(for: arg)
        case "--output":
            output = value(for: arg)
        case "--espeak-data":
            espeakData = value(for: arg)
        case "--text-file":
            textFile = value(for: arg)
        case "--stdin":
            useStdin = true
        case "--ssml":
            isSSML = true
        case "--speaker-id":
            let raw = value(for: arg)
            guard let parsed = Int32(raw) else {
                fail("--speaker-id must be an integer, got '\(raw)'")
            }
            speakerId = parsed
        default:
            if arg.hasPrefix("--") {
                fail("unknown option '\(arg)'", showUsage: true)
            }
            positional.append(arg)
        }
        i += 1
    }

    guard let model, let config, let output else {
        fail("--model, --config and --output are required", showUsage: true)
    }

    let textSources = [textFile != nil, useStdin, !positional.isEmpty].filter { $0 }.count
    guard textSources == 1 else {
        fail("provide the text exactly once: positional text, --text-file, or --stdin", showUsage: true)
    }

    let text: String
    if let textFile {
        do {
            text = try String(contentsOfFile: textFile, encoding: .utf8)
        } catch {
            fail("cannot read text file '\(textFile)': \(error.localizedDescription)")
        }
    } else if useStdin {
        let data = FileHandle.standardInput.readDataToEndOfFile()
        guard let stdinText = String(data: data, encoding: .utf8) else {
            fail("stdin is not valid UTF-8")
        }
        text = stdinText
    } else {
        text = positional.joined(separator: " ")
    }

    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
        fail("text is empty")
    }

    return Options(model: model, config: config, output: output, espeakData: espeakData,
                   text: trimmed, isSSML: isSSML, speakerId: speakerId)
}

@main
struct PiperCLI {
    static func main() async {
        let options = parse(Array(CommandLine.arguments.dropFirst()))

        let piper: Piper
        do {
            if let espeakData = options.espeakData {
                piper = try Piper(modelPath: options.model, configPath: options.config,
                                  espeakNGData: espeakData)
            } else {
                piper = try Piper(modelPath: options.model, andConfigPath: options.config)
            }
        } catch {
            fputs("piper-cli: cannot create synthesizer: \(error)\n", stderr)
            exit(1)
        }

        if options.isSSML {
            await piper.synthesizeSSML(options.text, speakerId: options.speakerId,
                                       toFileAtPath: options.output)
        } else {
            await piper.synthesize(options.text, toFileAtPath: options.output)
        }

        guard let attributes = try? FileManager.default.attributesOfItem(atPath: options.output),
              let size = attributes[.size] as? NSNumber, size.intValue > 0 else {
            fputs("piper-cli: synthesis produced no output at '\(options.output)'\n", stderr)
            exit(1)
        }

        print(options.output)
    }
}
