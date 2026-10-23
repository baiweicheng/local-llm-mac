import Foundation
import MusicKit

/// Phase 5: music via MusicKit — the public API route on macOS.
///
/// Library search is real and shipped: it searches the user's own
/// library (songs they've added or own). Playback state is the honest
/// gap: macOS gives apps NO public way to see what another app is
/// playing — the "MediaRemote" framework that used to expose it is
/// private, and since macOS 15.4 it's gated behind a special
/// entitlement even for private use. So `nowPlaying()` says exactly
/// that rather than guessing, and this file never touches a private
/// API.
enum MusicService {

    static func searchLibrary(term rawTerm: String, limit: Int) async -> String {
        let term = rawTerm.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else {
            return "No search phrase was given."
        }
        do {
            var request = MusicLibrarySearchRequest(term: term, types: [Song.self])
            request.limit = limit
            let response = try await request.response()
            let songs = response.songs
            guard !songs.isEmpty else {
                return "No songs in the library matched “\(term)”."
            }
            var lines = ["Songs matching “\(term)”:"]
            for song in songs {
                var line = "• \(song.title) — \(song.artistName)"
                if let album = song.albumTitle, !album.isEmpty {
                    line += " (\(album))"
                }
                lines.append(line)
            }
            return lines.joined(separator: "\n")
        } catch {
            return "Music search couldn't run. macOS may require the packaged app (built with Scripts/make-app.sh — see the README) with its MusicKit entitlement before the library can be searched; the library itself wasn't changed."
        }
    }

    /// The documented gap, in the words the model can pass along.
    static func nowPlaying() -> String {
        "I can't see what's playing right now — macOS doesn't let apps look at what other apps are playing (there's no public API for it). The user can see it in Control Center or the Music app."
    }
}
