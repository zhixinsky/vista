// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI
import UIKit

@MainActor
final class CropOrientationSession {
    private weak var scene: UIWindowScene?
    private var previous = UIInterfaceOrientation.unknown

    func enter(_ scene: UIWindowScene) {
        guard self.scene == nil else { return }
        self.scene = scene
        previous = scene.interfaceOrientation
        guard !previous.isLandscape else { return }
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: .landscape))
    }

    func restore() {
        defer { scene = nil; previous = .unknown }
        guard let scene, scene.interfaceOrientation != previous else { return }
        let mask: UIInterfaceOrientationMask
        switch previous {
        case .portrait: mask = .portrait
        case .portraitUpsideDown: mask = .portraitUpsideDown
        case .landscapeLeft: mask = .landscapeLeft
        case .landscapeRight: mask = .landscapeRight
        default: return
        }
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask))
    }
}

struct CropLandscapeLayout: ViewModifier {
    let session: CropOrientationSession

    func body(content: Content) -> some View {
        GeometryReader { geometry in
            let sideways = geometry.size.height > geometry.size.width
            content
                .frame(width: sideways ? geometry.size.height : geometry.size.width,
                       height: sideways ? geometry.size.width : geometry.size.height)
                .rotationEffect(sideways ? .degrees(90) : .zero)
                .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
        }
        .background(SceneReader(onAttach: session.enter).allowsHitTesting(false))
    }
}

private struct SceneReader: UIViewRepresentable {
    let onAttach: (UIWindowScene) -> Void

    func makeUIView(context: Context) -> AttachedView {
        let view = AttachedView()
        view.onAttach = onAttach
        return view
    }

    func updateUIView(_ view: AttachedView, context: Context) {
        view.onAttach = onAttach
    }

    final class AttachedView: UIView {
        var onAttach: ((UIWindowScene) -> Void)?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            Task { @MainActor [weak self] in
                guard let self, let scene = window?.windowScene else { return }
                onAttach?(scene)
            }
        }
    }
}
