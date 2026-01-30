//
//  WaveformView.swift
//  VoiceClone
//

import SwiftUI

struct WaveformView: View {
    let samples: [Float]
    let progress: Double

    var body: some View {
        GeometryReader { proxy in
            Canvas { context, size in
                guard !samples.isEmpty else { return }

                let midY = size.height / 2
                let step = max(1, samples.count / Int(size.width))

                var path = Path()
                var x: CGFloat = 0
                var index = 0
                while index < samples.count {
                    let sample = samples[index]
                    let clamped = max(-1, min(1, sample))
                    let y = midY - CGFloat(clamped) * midY
                    if x == 0 {
                        path.move(to: CGPoint(x: x, y: y))
                    } else {
                        path.addLine(to: CGPoint(x: x, y: y))
                    }
                    x += 1
                    index += step
                }

                context.stroke(path, with: .color(.accentColor), lineWidth: 1)

                if progress > 0 {
                    let progressX = size.width * CGFloat(progress)
                    let progressRect = CGRect(x: 0, y: 0, width: progressX, height: size.height)
                    context.fill(Path(progressRect), with: .color(.accentColor.opacity(0.1)))
                }
            }
        }
    }
}

#Preview {
    WaveformView(samples: (0..<200).map { _ in Float.random(in: -1...1) }, progress: 0.3)
        .frame(height: 80)
        .padding()
}
