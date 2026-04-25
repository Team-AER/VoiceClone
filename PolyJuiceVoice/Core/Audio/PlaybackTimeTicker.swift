//
//  PlaybackTimeTicker.swift
//  PolyJuiceVoice
//
//  Cross-platform replacement for CADisplayLink (iOS-only).
//  On macOS uses a DispatchSourceTimer at ~60 Hz.
//  On iOS uses CADisplayLink for best efficiency.
//

import Foundation

#if os(iOS)
import UIKit
#endif

final class PlaybackTimeTicker {

    private let handler: () -> Void
    private var isRunning = false

    #if os(iOS)
    private var displayLink: CADisplayLink?
    #elseif os(macOS)
    private var timer: DispatchSourceTimer?
    #endif

    init(handler: @escaping () -> Void) {
        self.handler = handler
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true

        #if os(iOS)
        let link = CADisplayLink(target: self, selector: #selector(tick))
        link.add(to: .main, forMode: .common)
        displayLink = link
        #elseif os(macOS)
        let source = DispatchSource.makeTimerSource(queue: .main)
        source.schedule(deadline: .now(), repeating: 1.0 / 60.0)
        source.setEventHandler { [weak self] in self?.handler() }
        source.resume()
        timer = source
        #endif
    }

    func stop() {
        isRunning = false

        #if os(iOS)
        displayLink?.invalidate()
        displayLink = nil
        #elseif os(macOS)
        timer?.cancel()
        timer = nil
        #endif
    }

    #if os(iOS)
    @objc private func tick() {
        handler()
    }
    #endif
}
