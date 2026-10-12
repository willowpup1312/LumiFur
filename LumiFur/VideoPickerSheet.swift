//
//  VideoPickerSheet.swift
//  LumiFur
//
//  Created by Afton on 10/12/26.
//


import SwiftUI

struct VideoPickerSheet: View {
    let videos: [String]
    let currentIndex: Int
    let onSelect: (Int) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List(videos.indices, id: \.self) { index in
                Button {
                    onSelect(index)
                    dismiss()
                } label: {
                    HStack {
                        Text(videos[index])
                            .foregroundStyle(.primary)
                        Spacer()
                        if index == currentIndex {
                            Image(systemName: "checkmark")
                                .foregroundStyle(.tint)
                        }
                    }
                }
            }
            .navigationTitle("Select Video")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

struct VideoPlayerAccessory: View {
    @ObservedObject var viewModel: AccessoryViewModel
    @State private var showPicker = false

    private let videoPlayerViewID = 29

    var body: some View {
        if viewModel.selectedView == videoPlayerViewID {
            Button {
                viewModel.refreshVideoList()
                showPicker = true
            } label: {
                Label("Choose Video", systemImage: "film")
            }
            .sheet(isPresented: $showPicker) {
                VideoPickerSheet(
                    videos: viewModel.videoList,
                    currentIndex: viewModel.currentVideoIndex
                ) { index in
                    viewModel.selectVideo(at: index)
                }
            }
            .onAppear {
                viewModel.refreshVideoList()
            }
        }
    }
}