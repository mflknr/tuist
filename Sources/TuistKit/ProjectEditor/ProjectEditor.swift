import Foundation
import TSCBasic
import TuistCore
import TuistGenerator
import TuistGraph
import TuistLoader
import TuistScaffold
import TuistSupport

enum ProjectEditorError: FatalError, Equatable {
    /// This error is thrown when we try to edit in a project in a directory that has no editable files.
    case noEditableFiles(AbsolutePath)

    var type: ErrorType {
        switch self {
        case .noEditableFiles: return .abort
        }
    }

    var description: String {
        switch self {
        case let .noEditableFiles(path):
            return "There are no editable files at \(path.pathString)"
        }
    }
}

protocol ProjectEditing: AnyObject {
    /// Generates an Xcode project to edit the Project defined in the given directory.
    /// - Parameters:
    ///   - editingPath: Directory whose project will be edited.
    ///   - destinationDirectory: Directory in which the Xcode project will be generated.
    /// - Returns: The path to the generated Xcode project.
    func edit(at editingPath: AbsolutePath, in destinationDirectory: AbsolutePath) throws -> AbsolutePath
}

final class ProjectEditor: ProjectEditing {
    /// Project generator.
    let generator: DescriptorGenerating

    /// Project editor mapper.
    let projectEditorMapper: ProjectEditorMapping

    /// Project mapper
    let projectMapper: ProjectMapping

    /// Side effect descriptor executor
    let sideEffectDescriptorExecutor: SideEffectDescriptorExecuting

    /// Utility to locate Tuist's resources.
    let resourceLocator: ResourceLocating

    /// Utility to locate manifest files.
    let manifestFilesLocator: ManifestFilesLocating

    /// Utility to locate the helpers directory.
    let helpersDirectoryLocator: HelpersDirectoryLocating

    /// Utiltity to locate the custom templates directory
    let templatesDirectoryLocator: TemplatesDirectoryLocating

    /// Xcode Project writer
    private let writer: XcodeProjWriting

    init(
        generator: DescriptorGenerating = DescriptorGenerator(),
        projectEditorMapper: ProjectEditorMapping = ProjectEditorMapper(),
        resourceLocator: ResourceLocating = ResourceLocator(),
        manifestFilesLocator: ManifestFilesLocating = ManifestFilesLocator(),
        helpersDirectoryLocator: HelpersDirectoryLocating = HelpersDirectoryLocator(),
        writer: XcodeProjWriting = XcodeProjWriter(),
        templatesDirectoryLocator: TemplatesDirectoryLocating = TemplatesDirectoryLocator(),
        projectMapper: ProjectMapping = SequentialProjectMapper(
            mappers: [
                AutogeneratedSchemesProjectMapper(enableCodeCoverage: false),
            ]
        ),
        sideEffectDescriptorExecutor: SideEffectDescriptorExecuting = SideEffectDescriptorExecutor()
    ) {
        self.generator = generator
        self.projectEditorMapper = projectEditorMapper
        self.resourceLocator = resourceLocator
        self.manifestFilesLocator = manifestFilesLocator
        self.helpersDirectoryLocator = helpersDirectoryLocator
        self.writer = writer
        self.templatesDirectoryLocator = templatesDirectoryLocator
        self.projectMapper = projectMapper
        self.sideEffectDescriptorExecutor = sideEffectDescriptorExecutor
    }

    func edit(at editingPath: AbsolutePath, in dstDirectory: AbsolutePath) throws -> AbsolutePath {
        let xcodeprojPath = dstDirectory.appending(component: "Manifests.xcodeproj")

        let projectDesciptionPath = try resourceLocator.projectDescription()
        let manifests = manifestFilesLocator.locateAllProjectManifests(at: editingPath)
        let configPath = manifestFilesLocator.locateConfig(at: editingPath)
        let dependenciesPath = manifestFilesLocator.locateDependencies(at: editingPath)
        let setupPath = manifestFilesLocator.locateSetup(at: editingPath)
        var helpers: [AbsolutePath] = []
        if let helpersDirectory = helpersDirectoryLocator.locate(at: editingPath) {
            helpers = FileHandler.shared.glob(helpersDirectory, glob: "**/*.swift")
        }
        var templates: [AbsolutePath] = []
        if let templatesDirectory = templatesDirectoryLocator.locateUserTemplates(at: editingPath) {
            templates = FileHandler.shared.glob(templatesDirectory, glob: "**/*.swift")
                + FileHandler.shared.glob(templatesDirectory, glob: "**/*.stencil")
        }

        /// We error if the user tries to edit a project in a directory where there are no editable files.
        if manifests.isEmpty, helpers.isEmpty, templates.isEmpty {
            throw ProjectEditorError.noEditableFiles(editingPath)
        }

        // To be sure that we are using the same binary of Tuist that invoked `edit`
        let tuistPath = AbsolutePath(TuistCommand.processArguments()!.first!)

        let (project, graph) = try projectEditorMapper.map(tuistPath: tuistPath,
                                                           sourceRootPath: editingPath,
                                                           xcodeProjPath: xcodeprojPath,
                                                           setupPath: setupPath,
                                                           configPath: configPath,
                                                           dependenciesPath: dependenciesPath,
                                                           manifests: manifests.map(\.1),
                                                           helpers: helpers,
                                                           templates: templates,
                                                           projectDescriptionPath: projectDesciptionPath)

        let (mappedProject, sideEffects) = try projectMapper.map(project: project)
        try sideEffectDescriptorExecutor.execute(sideEffects: sideEffects)
        let valueGraph = ValueGraph(graph: graph)
        let graphTraverser = ValueGraphTraverser(graph: valueGraph)
        let descriptor = try generator.generateProject(project: mappedProject, graphTraverser: graphTraverser)
        try writer.write(project: descriptor)
        return descriptor.xcodeprojPath
    }
}
