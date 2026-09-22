import Testing
import Foundation
@_spi(Host) @testable import MaximalTreeKit
@testable import MaximalTree

/// What the drive was asked to do, and what it says about each item — set by
/// the test, since a temporary directory has no iCloud state of its own.
private final class Drive: @unchecked Sendable {
    var states: [String: DownloadState] = [:]
    var downloads: [String] = []
    var evictions: [String] = []
    var refuses = false
    /// The app folders Finder would show, by container, and what they're called.
    var apps: [String: String] = [:]
    struct Refused: LocalizedError { var errorDescription: String? { "iCloud said no." } }
}

/// iCloud Drive as the file it is: the file plugin's listings, worn by iCloud
/// items, plus the one thing only iCloud knows — whether the bytes are here.
@MainActor
@Suite struct ICloudTests {
    /// iCloud Drive's own folder, inside a temporary copy of the place iCloud
    /// keeps its containers — with an app's container beside it that Finder
    /// would show, and one it wouldn't.
    private func makeRoot() throws -> URL {
        let containers = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("icloud-\(UUID().uuidString)", isDirectory: true)
        let root = containers.appendingPathComponent(ICloudDrive.driveContainer, isDirectory: true)
        let files = FileManager.default
        try files.createDirectory(at: root.appendingPathComponent("Notes"), withIntermediateDirectories: true)
        try Data("hi".utf8).write(to: root.appendingPathComponent("Notes/a b.txt"))
        try Data().write(to: root.appendingPathComponent("plan.txt"))
        for container in ["com~apple~Pages", "com~apple~mail"] {
            try files.createDirectory(at: containers.appendingPathComponent("\(container)/Documents"),
                                      withIntermediateDirectories: true)
        }
        try Data().write(to: containers.appendingPathComponent("com~apple~Pages/Documents/Essay.pages"))
        try Data().write(to: containers.appendingPathComponent("com~apple~mail/Documents/state"))
        return root
    }

    private func containers(_ root: URL) -> URL { root.deletingLastPathComponent() }

    private func drive(_ root: URL, _ recorder: Drive = Drive()) -> ICloudDrive {
        ICloudDrive(containers: containers(root),
                    state: { recorder.states[$0.lastPathComponent] },
                    download: { url in
                        if recorder.refuses { throw Drive.Refused() }
                        recorder.downloads.append(url.lastPathComponent)
                    },
                    evict: { recorder.evictions.append($0.lastPathComponent) },
                    appFolder: { recorder.apps[$0.lastPathComponent] })
    }

    private func provider(_ drive: ICloudDrive) -> ICloudProvider {
        let broker = HostBroker()
        broker.install([FileSystemProvider()])      // only file:// — iCloud composes over it
        return ICloudProvider(drive: drive, broker: broker)
    }

    private func id(_ uri: String) throws -> NodeID { try #require(NodeID(uri)) }

    // MARK: Addresses

    @Test func anItemAndItsPlaceOnDiskAreOneAnother() throws {
        let root = try makeRoot()
        let drive = drive(root)
        let item = try #require(drive.id(for: root.appendingPathComponent("Notes/a b.txt")))
        #expect(item.uri == "icloud://drive/Notes/a%20b.txt")
        #expect(drive.url(for: item)?.path == root.appendingPathComponent("Notes/a b.txt").path)
        #expect(drive.id(for: root) == ICloudDrive.rootID)
    }

    /// A URI can come from a keymap or a script now, not only from a listing,
    /// so one that climbs out of the drive is turned away rather than trusted.
    @Test func anAddressThatLeavesTheDriveIsRefused() throws {
        let drive = drive(try makeRoot())
        for uri in ["icloud://drive/../outside", "icloud://drive/Notes/../../outside",
                    "icloud://drive/./plan.txt", "icloud://other/plan.txt", "file:///tmp/plan.txt"] {
            #expect(drive.url(for: try id(uri)) == nil, "\(uri) was let through")
        }
    }

    /// A folder whose name merely starts with the drive's is not inside it.
    @Test func aNeighbourWithASimilarNameIsNotInTheDrive() throws {
        let root = try makeRoot()
        let neighbour = URL(fileURLWithPath: root.path + "-elsewhere/plan.txt")
        #expect(drive(root).id(for: neighbour) == nil)
    }

    // MARK: What an item is

    @Test func theDriveIsCalledWhatItIs() async throws {
        let node = try #require(await provider(drive(try makeRoot())).node(for: ICloudDrive.rootID))
        #expect(node.label == "iCloud Drive")
        #expect(node.hasChildren)
    }

    /// Listed by the file plugin, worn by iCloud: the file is its identity,
    /// which brings every file action and the file inspector with it, and its
    /// anchor, which makes opening it open the file.
    @Test func anItemIsTheFileItAlsoIs() async throws {
        let root = try makeRoot()
        let children = await provider(drive(root)).children(of: ICloudDrive.rootID, page: nil)

        #expect(children.items.map(\.label) == ["Notes", "plan.txt"], "not the file plugin's order")
        let plan = try #require(children.items.first { $0.label == "plan.txt" })
        let file = try #require(NodeID(root.appendingPathComponent("plan.txt")
            .standardizedFileURL.absoluteString))

        #expect(plan.id.uri == "icloud://drive/plan.txt")
        #expect(plan.type == ICloudProvider.fileType)
        #expect(plan.identities == [file])
        #expect(plan.anchor?.node == file)

        let notes = try #require(children.items.first { $0.label == "Notes" })
        #expect(notes.type == ICloudProvider.directoryType)
        #expect(notes.hasChildren)
    }

    @Test func goingDeeperStaysInICloud() async throws {
        let root = try makeRoot()
        let inside = await provider(drive(root)).children(of: try id("icloud://drive/Notes"), page: nil)
        #expect(inside.items.map(\.id.uri) == ["icloud://drive/Notes/a%20b.txt"])
    }

    // MARK: Apps' folders

    /// The top of the drive is also every app folder Finder would show —
    /// each a container of its own on disk — and none it wouldn't.
    @Test func theDriveHasItsAppsFoldersToo() async throws {
        let root = try makeRoot()
        let recorder = Drive()
        recorder.apps = ["com~apple~Pages": "Pages"]
        let items = await provider(drive(root, recorder)).children(of: ICloudDrive.rootID, page: nil).items

        #expect(items.map(\.label) == ["Notes", "Pages", "plan.txt"], "not merged in Finder's order")
        let pages = try #require(items.first { $0.label == "Pages" })
        #expect(pages.id.uri == "icloud://app/com~apple~Pages")
        #expect(pages.type == ICloudProvider.directoryType)
        let documents = containers(root).appendingPathComponent("com~apple~Pages/Documents")
        #expect(pages.identities == [try #require(NodeID(documents.standardizedFileURL.absoluteString))])
        #expect(!items.contains { $0.id.uri.contains("mail") }, "a private container was shown")
    }

    /// Called after its app, not after the "Documents" folder it is on disk.
    @Test func anAppFolderIsCalledAfterItsApp() async throws {
        let root = try makeRoot()
        let recorder = Drive()
        recorder.apps = ["com~apple~Pages": "Pages"]
        let node = try #require(await provider(drive(root, recorder))
            .node(for: try id("icloud://app/com~apple~Pages")))
        #expect(node.label == "Pages")
    }

    @Test func goingIntoAnAppFolderListsItsDocuments() async throws {
        let root = try makeRoot()
        let inside = await provider(drive(root)).children(of: try id("icloud://app/com~apple~Pages"), page: nil)
        #expect(inside.items.map(\.id.uri) == ["icloud://app/com~apple~Pages/Essay.pages"])
    }

    @Test func anAppsDocumentAndItsPlaceOnDiskAreOneAnother() throws {
        let root = try makeRoot()
        let drive = drive(root)
        let essay = containers(root).appendingPathComponent("com~apple~Pages/Documents/Essay.pages")
        let item = try #require(drive.id(for: essay))
        #expect(item.uri == "icloud://app/com~apple~Pages/Essay.pages")
        #expect(drive.url(for: item)?.path == essay.path)

        // The container itself is not an address; its documents are.
        #expect(drive.id(for: containers(root).appendingPathComponent("com~apple~Pages")) == nil)
        // And iCloud Drive's own folder is always the drive, never an "app".
        #expect(drive.id(for: root.appendingPathComponent("plan.txt"))?.uri == "icloud://drive/plan.txt")
    }

    @Test func anAppAddressThatLeavesItsFolderIsRefused() throws {
        let drive = drive(try makeRoot())
        for uri in ["icloud://app", "icloud://app/../outside", "icloud://app/com~apple~Pages/../../outside",
                    "icloud://app/com~apple~CloudDocs/plan.txt"] {
            #expect(drive.url(for: try id(uri)) == nil, "\(uri) was let through")
        }
    }

    // MARK: Mounting a folder of it

    @Test func aFolderInTheDriveCanBeMounted() throws {
        let root = try makeRoot()
        let recorder = Drive()
        recorder.apps = ["com~apple~Pages": "Pages"]
        let drive = drive(root, recorder)
        #expect(try ICloudPlugin.address(of: root.appendingPathComponent("Notes"), in: drive).uri
                == "icloud://drive/Notes")
        #expect(try ICloudPlugin.address(of: containers(root).appendingPathComponent("com~apple~Pages/Documents"),
                                         in: drive).uri == "icloud://app/com~apple~Pages")
    }

    /// The folder panel can wander anywhere; only somewhere Finder shows as
    /// iCloud has an iCloud address, and the refusal says what to do instead.
    @Test func aFolderElsewhereIsRefusedWithAReason() throws {
        let root = try makeRoot()
        let drive = drive(root)
        #expect(throws: ICloudPlugin.NotInICloud.self) {
            _ = try ICloudPlugin.address(of: URL(fileURLWithPath: NSTemporaryDirectory()), in: drive)
        }
        #expect(throws: ICloudPlugin.NotInICloud.self) {
            _ = try ICloudPlugin.address(of: containers(root).appendingPathComponent("com~apple~mail/Documents"),
                                         in: drive)
        }
        let reason = ICloudPlugin.NotInICloud(url: URL(fileURLWithPath: "/tmp/Stuff")).errorDescription ?? ""
        #expect(reason.contains("Stuff") && reason.contains("Mount Root"))
    }

    // MARK: Where the bytes are

    @Test func whereTheBytesAreIsOnTheRecord() async throws {
        let root = try makeRoot()
        let recorder = Drive()
        recorder.states = ["plan.txt": .inCloud, "Notes": .inCloud]
        let items = await provider(drive(root, recorder)).children(of: ICloudDrive.rootID, page: nil).items

        let plan = try #require(items.first { $0.label == "plan.txt" })
        #expect(ICloudProvider.state(of: plan) == .inCloud)
        #expect(plan.icon?.systemName == "icloud.and.arrow.down", "nothing says it will take a moment")

        // A folder still reads as a folder: opening one lists it, it doesn't
        // wait on a download, so the warning would be a false one.
        let notes = try #require(items.first { $0.label == "Notes" })
        #expect(ICloudProvider.state(of: notes) == .inCloud)
        #expect(notes.icon?.systemName == "folder.fill", "a folder lost its folder icon")
    }

    /// Something iCloud doesn't track has no state at all, rather than a guess.
    @Test func somethingICloudDoesNotTrackSaysNothing() async throws {
        let items = await provider(drive(try makeRoot())).children(of: ICloudDrive.rootID, page: nil).items
        #expect(items.allSatisfy { ICloudProvider.state(of: $0) == nil })
    }

    // MARK: Bringing it down, letting it go

    private func context(_ nodes: [Node]) -> ActionContext {
        let host = HostContext()
        nodes.forEach { host._ingest($0) }
        return ActionContext(host: host, targets: nodes.map(\.id))
    }

    private func item(_ uri: String, _ state: DownloadState?) throws -> Node {
        var node = Node(id: try id(uri), type: ICloudProvider.fileType)
        if let state { node.attributes["icloud"] = .string(state.rawValue) }
        return node
    }

    /// Whether the action registered under `id` is offered for an item in
    /// `state` — asked of the registered action, not of a helper, so what is
    /// checked is what the menu will actually do.
    private func offers(_ id: String, _ state: DownloadState?) throws -> Bool {
        let registry = Registry()
        ICloudPlugin().register(with: registry)
        let action = try #require(registry.actions.first { $0.id == id })
        return action.appliesTo.matches(context([try item("icloud://drive/a", state)]))
    }

    @Test func downloadingIsOfferedOnlyForWhatIsNotHereYet() throws {
        #expect(try offers("icloud.download", .inCloud))
        #expect(try offers("icloud.download", .behind))
        #expect(try !offers("icloud.download", .current))
        #expect(try !offers("icloud.download", nil))
    }

    /// Only what is fully here and current can be let go of. Evicting something
    /// iCloud is still waiting on is how a change made offline gets lost.
    @Test func lettingGoIsOfferedOnlyForWhatIsCurrent() throws {
        #expect(try offers("icloud.evict", .current))
        #expect(try !offers("icloud.evict", .behind), "something iCloud is behind on could be let go of")
        #expect(try !offers("icloud.evict", .inCloud))
        #expect(try !offers("icloud.evict", nil))
    }

    /// Every target has to be one; a mixed selection gets neither.
    @Test func aFileThatIsNotInICloudGetsNeither() throws {
        let local = Node(id: try id("file:///tmp/a.txt"), type: .file)
        let mixed = context([try item("icloud://drive/a", .inCloud), local])
        #expect(!ICloudPlugin.all(mixed, in: [.inCloud, .behind]))
        #expect(!ICloudPlugin.all(context([]), in: [.inCloud]))
    }

    @Test func eachTargetIsHandedToICloud() throws {
        let root = try makeRoot()
        let recorder = Drive()
        let drive = drive(root, recorder)
        let ctx = context([try item("icloud://drive/plan.txt", .inCloud),
                           try item("icloud://drive/Notes/a%20b.txt", .inCloud)])

        try ICloudPlugin.each(ctx, drive: drive, with: drive.download)
        #expect(recorder.downloads == ["plan.txt", "a b.txt"])
    }

    /// And a refusal reaches the reader instead of the log.
    @Test func aRefusalIsAFailure() throws {
        let recorder = Drive()
        recorder.refuses = true
        let drive = drive(try makeRoot(), recorder)
        let ctx = context([try item("icloud://drive/plan.txt", .inCloud)])
        #expect(throws: Drive.Refused.self) {
            try ICloudPlugin.each(ctx, drive: drive, with: drive.download)
        }
    }

    // MARK: With the file plugin, unmodified

    private func makeModel(on root: URL) throws -> AppModel {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("icloud-model-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let model = AppModel(host: HostContext(),
                             workspaceFile: dir.appendingPathComponent("workspaces.json"))
        model.start()
        FileSystemPlugin().register(with: model.pluginHost.registry)
        ICloudPlugin().register(with: model.pluginHost.registry)
        return model
    }

    /// An item's record and the file's, as the tree would have loaded them.
    private func load(_ uri: String, root: URL, into model: AppModel) async throws -> Node {
        let item = try #require(await provider(drive(root)).node(for: try id(uri)))
        let fileID = try #require(item.identities.first)
        let file = try #require(await FileSystemProvider().node(for: fileID))
        model.host._ingest(item)
        model.host._ingest(file)
        return item
    }

    /// The claim this plugin rests on: nothing in the file plugin knows iCloud
    /// exists, and every file action still reaches an iCloud item — handed the
    /// file it is, because that is the identity that understands files.
    @Test func theFileActionsReachAnICloudItem() async throws {
        let root = try makeRoot()
        let previous = ICloudPlugin.drive
        ICloudPlugin.drive = drive(root)
        defer { ICloudPlugin.drive = previous }
        let model = try makeModel(on: root)
        let item = try await load("icloud://drive/plan.txt", root: root, into: model)

        let offered = Set(model.applicableActions(for: [item.id]).map(\.id))
        for action in ["file.duplicate", "file.trash", "file.copyPath", "file.reveal", "file.openDefault"] {
            #expect(offered.contains(action), "\(action) did not reach the iCloud item")
        }
    }

    /// And run against the file, not the iCloud address: duplicating makes a
    /// real copy on disk, beside the original.
    @Test func aFileActionActsOnTheFileItIs() async throws {
        let root = try makeRoot()
        let previous = ICloudPlugin.drive
        ICloudPlugin.drive = drive(root)
        defer { ICloudPlugin.drive = previous }
        let model = try makeModel(on: root)
        let item = try await load("icloud://drive/plan.txt", root: root, into: model)
        let duplicate = try #require(model.action("file.duplicate"))

        model.perform(duplicate, targets: [item.id])
        for _ in 0..<400 where !FileManager.default.fileExists(
            atPath: root.appendingPathComponent("plan 2.txt").path) {
            try await Task.sleep(for: .milliseconds(5))
        }

        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("plan 2.txt").path),
                "the file action never reached the file")
        #expect(model.commandFailure == nil, "\(model.commandFailure?.message ?? "")")
    }

    /// Opening one opens the file, in whatever canvas files open in — there is
    /// no iCloud canvas, because there is nothing an iCloud item shows that
    /// the file doesn't.
    @Test func openingAnItemOpensTheFile() async throws {
        let root = try makeRoot()
        let model = try makeModel(on: root)
        let item = try await load("icloud://drive/plan.txt", root: root, into: model)

        model.store?.open(item.id)
        #expect(model.navigation.current == item.anchor?.node)
        #expect(model.navigation.current?.scheme == "file")
    }

    // MARK: Keeping up

    /// A download finishing is a file event like any other. The item redraws
    /// and its folder relists; nothing claims a rename it can't be sure of.
    @Test func iCloudMovingThingsRedrawsTheRows() throws {
        let root = try makeRoot()
        let drive = drive(root)
        let changes = ICloudProvider.changes(for: [
            .init(path: root.appendingPathComponent("Notes/a b.txt").path, mustRescanSubtree: false),
            .init(path: root.appendingPathComponent("Notes/a b.txt").path, mustRescanSubtree: false),
        ], in: drive)
        #expect(changes == [.modified(try id("icloud://drive/Notes/a%20b.txt")),
                            .childrenChanged(try id("icloud://drive/Notes"))],
                "a burst about one item became more than one redraw")
    }

    /// Safari's history and Mail's state change all the time, and nothing in
    /// them is in the tree.
    @Test func aPrivateContainerIsNotReported() throws {
        let root = try makeRoot()
        let recorder = Drive()
        recorder.apps = ["com~apple~Pages": "Pages"]
        let drive = drive(root, recorder)
        let mail = containers(root).appendingPathComponent("com~apple~mail/Documents/state").path
        let essay = containers(root).appendingPathComponent("com~apple~Pages/Documents/Essay.pages").path

        #expect(ICloudProvider.changes(for: [.init(path: mail, mustRescanSubtree: false)], in: drive).isEmpty)
        #expect(ICloudProvider.changes(for: [.init(path: essay, mustRescanSubtree: false)], in: drive)
                == [.modified(try id("icloud://app/com~apple~Pages/Essay.pages")),
                    .childrenChanged(try id("icloud://app/com~apple~Pages"))])
    }

    /// A new app starting to keep documents in iCloud is the top of the drive
    /// changing.
    @Test func aContainerAppearingRelistsTheTop() throws {
        let root = try makeRoot()
        let numbers = containers(root).appendingPathComponent("com~apple~Numbers").path
        #expect(ICloudProvider.changes(for: [.init(path: numbers, mustRescanSubtree: false)], in: drive(root))
                == [.childrenChanged(ICloudDrive.rootID)])
    }

    @Test func somethingOutsideTheDriveIsNotReported() throws {
        let changes = ICloudProvider.changes(for: [.init(path: "/tmp/elsewhere.txt", mustRescanSubtree: false)],
                                             in: drive(try makeRoot()))
        #expect(changes.isEmpty)
    }
}

/// Files from somewhere that isn't this disk, and can't be written to.
///
/// Nothing ships like this today, which is exactly why it needs a test: every
/// file node the app has seen so far is on disk, so a predicate that asked
/// "is this a file?" when its body needed "is there a path?" gave the same
/// answer and nothing noticed.
private struct FarAwayFiles: NodeProvider {
    let schemes: Set<String> = ["faraway"]
    func resolve(_ uri: String) -> NodeID? { NodeID(uri) }
    func node(for id: NodeID) async -> Node? { nil }
    func children(of id: NodeID, page cursor: Cursor?) async -> Page<Node> { Page(items: []) }
}

/// A menu offers only what its bodies can do.
@MainActor
@Suite struct FileActionHonestyTests {
    private func makeModel() throws -> AppModel {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("honesty-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let model = AppModel(host: HostContext(),
                             workspaceFile: dir.appendingPathComponent("workspaces.json"))
        model.start()
        model.pluginHost.registry.register(provider: FarAwayFiles())
        FileSystemPlugin().register(with: model.pluginHost.registry)
        return model
    }

    private func offered(_ model: AppModel, for node: Node) -> Set<String> {
        model.host._ingest(node)
        return Set(model.applicableActions(for: [node.id]).map(\.id))
    }

    /// A file with no path gets nothing that needs one. Revealing it, copying
    /// its path, duplicating it, or handing it to another app would each have
    /// quietly done nothing.
    @Test func aFileWithNoPathIsOfferedNothingThatNeedsOne() throws {
        let model = try makeModel()
        let far = Node(id: try #require(NodeID("faraway://server/a.txt")), type: .file)
        let actions = offered(model, for: far)
        for id in ["file.reveal", "file.copyPath", "file.duplicate", "file.openDefault"] {
            #expect(!actions.contains(id), "\(id) was offered for a file with no path")
        }
    }

    /// And its owner is asked before anything is made in it or thrown away.
    @Test func whatItsOwnerCannotDoIsNotOffered() throws {
        let model = try makeModel()
        let far = Node(id: try #require(NodeID("faraway://server/a.txt")), type: .file)
        #expect(!offered(model, for: far).contains("file.trash"))

        let folder = Node(id: try #require(NodeID("faraway://server/folder")), type: .directory)
        let actions = offered(model, for: folder)
        #expect(!actions.contains("file.newFile"))
        #expect(!actions.contains("file.newFolder"))
    }

    /// The control: the same file, on disk, gets all of it — so the absences
    /// above are the predicate's answer and not an empty menu.
    @Test func theSameFileOnDiskGetsEverything() throws {
        let model = try makeModel()
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("honest-\(UUID().uuidString).txt")
        try Data().write(to: url)
        let here = Node(id: try #require(NodeID(url.standardizedFileURL.absoluteString)), type: .file)
        let actions = offered(model, for: here)
        for id in ["file.reveal", "file.copyPath", "file.duplicate", "file.openDefault", "file.trash"] {
            #expect(actions.contains(id), "\(id) was not offered for a file on disk")
        }

        let folder = Node(id: try #require(NodeID(URL(fileURLWithPath: NSTemporaryDirectory())
            .standardizedFileURL.absoluteString)), type: .directory)
        #expect(offered(model, for: folder).contains("file.newFile"))
    }
}
