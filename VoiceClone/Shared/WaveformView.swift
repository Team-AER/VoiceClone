//
//  WaveformView.swift
//  VoiceClone
//

import SwiftUI

/// Symmetric vertical-bar waveform that always spans its container width.
///
/// Input is the pre-downsampled peak array maintained by each feature's
/// view model (`downsample(samples, to: 100)`); we ignore the original
/// sample-rate axis and just lay the bars out evenly across the canvas.
struct WaveformView: View {
    let samples: [Float]
    let progress: Double

    var body: some View {
        Canvas { context, size in
            guard !samples.isEmpty, size.width > 0, size.height > 0 else { return }

            let midY = size.height / 2
            let count = samples.count
            // Centre each bar in its column; account for stroke width so the
            // first/last bars sit a hair inside the canvas edges.
            let columnWidth = size.width / CGFloat(count)
            let barWidth = max(1.5, columnWidth * 0.6)
            // Reserve a 1 px floor so silence is still visible as a thin line.
            let minHalfHeight: CGFloat = 0.5
            let maxHalfHeight = midY - 1

            for (i, sample) in samples.enumerated() {
                let amp = CGFloat(min(1, max(0, abs(sample))))
                let halfHeight = max(minHalfHeight, amp * maxHalfHeight)
                let centerX = (CGFloat(i) + 0.5) * columnWidth

                let bar = Path { path in
                    path.move(to: CGPoint(x: centerX, y: midY - halfHeight))
                    path.addLine(to: CGPoint(x: centerX, y: midY + halfHeight))
                }
                context.stroke(
                    bar,
                    with: .color(.accentColor),
                    style: StrokeStyle(lineWidth: barWidth, lineCap: .round)
                )
            }

            // Playback progress wash.
            if progress > 0 {
                let progressX = size.width * CGFloat(min(1, max(0, progress)))
                let rect = CGRect(x: 0, y: 0, width: progressX, height: size.height)
                context.fill(Path(rect), with: .color(.accentColor.opacity(0.18)))
            }
        }
    }
}

#Preview("Random samples") {
    WaveformView(
        samples: (0..<100).map { i in
            Float(sin(Double(i) * 0.3)) * Float.random(in: 0.4...1.0)
        },
        progress: 0.4
    )
    .frame(height: 80)
    .padding()
    .background(.quaternary)
}

#Preview("Empty") {
    WaveformView(samples: [], progress: 0)
        .frame(height: 80)
        .padding()
        .background(.quaternary)
}
