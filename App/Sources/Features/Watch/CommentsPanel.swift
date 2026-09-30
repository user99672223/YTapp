import SwiftUI
import Core

/// The comments side panel, shared by the watch page and Shorts: a title with Done and the
/// scrolling list. The host places it at the trailing edge (width, material background, focus
/// section, transition) and keeps the video playing underneath; Back/Menu is handled by the
/// host, which closes the panel.
struct CommentsPanel: View {
    @ObservedObject var comments: CommentsModel
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Comments").font(.title3.bold())
                Spacer()
                Button("Done", action: close)
            }
            .padding(.horizontal, 40)
            .padding(.top, 50)
            .padding(.bottom, 20)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    CommentsList(comments: comments)
                }
                .padding(.horizontal, 40)
                .padding(.bottom, 60)
            }
        }
        .onAppear { comments.load() }
    }
}
