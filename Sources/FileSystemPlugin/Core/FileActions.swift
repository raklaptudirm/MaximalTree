import Foundation
import MaximalTreeKit

// What you can do to a file with no window — make one, make a folder, copy one,
// put it in the Trash. Mutations that fit the generic vocabulary go through
// `ctx.apply` (create, trash); duplicate's IO happens here and reports through
// `notify`. What needs the Mac — the pasteboard, Finder, another app — is the
// shell's, in FileSystem.swift. Rename is deliberately absent: the host's
// `core.rename` covers any provider supporting `.rename`, including this one.

/// True when every target is somewhere on this disk — which is what copying a
/// path, revealing in Finder, duplicating and handing a file to another app
/// all actually need.
///
/// Asked of where a node is rather than of its type. A type says what a thing
/// is; whether there is a path to give Finder is a different question, and
/// answering the first when the body needs the second is how a menu offers
/// something it then quietly fails to do. A node that only *is* a file by
/// another name — a repository, an iCloud item — is offered here as the file
/// it also is, so it still gets all of these.
@MainActor
func allOnDisk(_ ctx: ActionContext) -> Bool {
    !ctx.targets.isEmpty && ctx.targets.allSatisfy { $0.fileURL != nil }
}

/// The directory a creation action targets: the selected directory itself, or
/// nil when the selection isn't exactly one directory — or is one whose owner
/// can't make anything in it.
@MainActor
func targetDirectory(_ ctx: ActionContext) -> NodeID? {
    guard ctx.selectedNodes.count == 1, ctx.selectedNodes[0].type == directoryType,
          ctx.canApply(.create(in: ctx.selectedNodes[0].id, name: "untitled", asContainer: false))
    else { return nil }
    return ctx.selectedNodes[0].id
}

/// The file system's half that needs no window: the provider, and the actions
/// above. What a host with no window registers, and the first thing the Mac
/// plugin does.
enum FileSystemCore {
    @MainActor
    static func register(with registry: CoreRegistry) {
        registry.register(provider: FileSystemProvider())

        registry.register(action: Action(
            id: "file.newFile",
            title: "New File",
            systemImage: "doc.badge.plus",
            appliesTo: .custom { targetDirectory($0) != nil },
            scope: .container,
            run: { ctx in
                guard let dir = targetDirectory(ctx) else { return }
                // .txt rather than extensionless: gives the file a real content
                // type, so the editor claims it the moment it's opened.
                ctx.apply(.create(in: dir, name: "untitled.txt", asContainer: false))
            }
        ))

        registry.register(action: Action(
            id: "file.newFolder",
            title: "New Folder",
            systemImage: "folder.badge.plus",
            appliesTo: .custom { targetDirectory($0) != nil },
            scope: .container,
            run: { ctx in
                guard let dir = targetDirectory(ctx) else { return }
                ctx.apply(.create(in: dir, name: "untitled folder", asContainer: true))
            }
        ))

        registry.register(action: Action(
            id: "file.duplicate",
            title: "Duplicate",
            systemImage: "plus.square.on.square",
            appliesTo: .custom(allOnDisk),
            run: { ctx in
                let ids = ctx.selection
                // Copying can be big IO, so it happens off the main actor. Waiting
                // for it here is what puts it on the queue, and what lets a copy
                // that fails say so to the reader rather than to the log.
                let changes = try await Task.detached(priority: .userInitiated) {
                    try FileSystemProvider.duplicate(ids)
                }.value
                ctx.notify(changes)
            }
        ))

        registry.register(action: Action(
            id: "file.trash",
            title: "Move to Trash",
            systemImage: "trash",
            // Whether it can be put in the Trash is its owner's call, asked
            // rather than assumed from what kind of thing it is.
            appliesTo: .custom { ctx in !ctx.targets.isEmpty && ctx.canApply(.delete(ctx.targets)) },
            run: { ctx in ctx.apply(.delete(ctx.selection)) }
        ))
    }
}
