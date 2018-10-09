import Foundation

/// Generates the deterministic references of the project objects that have a temporary reference.
/// When objects are added to the project, those are added with a temporary reference that other
/// objects can refer to. Before saving the project, we make those references permanent giving them
/// a deterministic value that depends on the object itself and its ancestor.
protocol ReferenceGenerating: AnyObject {
    /// Generates the references of the objects of the given project.
    ///
    /// - Parameter proj: project whose objects references will be generated.
    func generateReferences(proj: PBXProj) throws
}

/// Reference generator.
final class ReferenceGenerator: ReferenceGenerating {
    /// Project pbxproj instance.
    var proj: PBXProj?

    /// Generates the references of the objects of the given project.
    ///
    /// - Parameter proj: project whose objects references will be generated.
    func generateReferences(proj: PBXProj) throws {
        guard let project: PBXProject = try proj.rootObjectReference?.objectOrThrow() else {
            return
        }

        self.proj = proj
        defer {
            self.proj = nil
        }

        // Projects, targets, groups and file references.
        // Note: The references of those type of objects should be generated first.
        ///      We use them to generate the references of the objects that depend on them.
        ///      For instance, the reference of a build file, is generated from the reference of
        ///      the file it refers to.
        let identifiers = [project.name]
        generateProjectAndTargets(project: project, identifiers: identifiers)
        try generateGroupReferences(project.mainGroup, identifiers: identifiers)
        if let productsGroup: PBXGroup = project.productsGroup {
            try generateGroupReferences(productsGroup, identifiers: identifiers)
        }

        // Targets
        let targets: [PBXTarget] = project.targets
        try targets.forEach({ try generateTargetReferences($0, identifiers: identifiers) })

        // Project references
        try project.projectReferences.flatMap({ $0.values }).forEach { objectReference in
            guard let fileReference: PBXFileReference = objectReference.object() else { return }
            try generateFileReference(fileReference, identifiers: identifiers)
        }

        /// Configuration list
        if let configurationList: XCConfigurationList = project.buildConfigurationListReference.object() {
            try generateConfigurationListReferences(configurationList, identifiers: identifiers)
        }
    }

    /// Generates the reference for the project and its target.
    ///
    /// - Parameters:
    ///   - project: project whose reference will be generated.
    ///   - identifiers: list of identifiers.
    func generateProjectAndTargets(project: PBXProject,
                                   identifiers: [String]) {
        // Project
        project.fixReference(identifiers: identifiers)

        // Targets
        let targets: [PBXTarget] = project.targetReferences.objects()
        targets.forEach { target in

            var identifiers = identifiers
            identifiers.append(target.name)

            target.fixReference(identifiers: identifiers)
        }
    }

    /// Generates the reference for a group object.
    ///
    /// - Parameters:
    ///   - group: group instance.
    ///   - identifiers: list of identifiers.
    fileprivate func generateGroupReferences(_ group: PBXGroup,
                                             identifiers: [String]) throws {
        var identifiers = identifiers
        if let groupName = group.fileName() {
            identifiers.append(groupName)
        }

        // Group
        group.fixReference(identifiers: identifiers)

        // Children
        try group.childrenReferences.forEach { child in
            guard let childFileElement: PBXFileElement = child.object() else { return }
            if let childGroup = childFileElement as? PBXGroup {
                try generateGroupReferences(childGroup, identifiers: identifiers)
            } else if let childFileReference = childFileElement as? PBXFileReference {
                try generateFileReference(childFileReference, identifiers: identifiers)
            }
        }
    }

    /// Generates the reference for a file reference object.
    ///
    /// - Parameters:
    ///   - fileReference: file reference instance.
    ///   - identifiers: list of identifiers.
    fileprivate func generateFileReference(_ fileReference: PBXFileReference, identifiers: [String]) throws {
        var identifiers = identifiers
        if let groupName = fileReference.fileName() {
            identifiers.append(groupName)
        }

        fileReference.fixReference(identifiers: identifiers)
    }

    /// Generates the reference for a configuration list object.
    ///
    /// - Parameters:
    ///   - configurationList: configuration list instance.
    ///   - identifiers: list of identifiers.
    fileprivate func generateConfigurationListReferences(_ configurationList: XCConfigurationList,
                                                         identifiers: [String]) throws {

        configurationList.fixReference(identifiers: identifiers)

        let buildConfigurations: [XCBuildConfiguration] = configurationList.buildConfigurations

        buildConfigurations.forEach { configuration in
            if !configuration.reference.temporary { return }

            var identifiers = identifiers
            identifiers.append(configuration.name)

            configuration.fixReference(identifiers: identifiers)
        }
    }

    /// Generates the reference for a target object.
    ///
    /// - Parameters:
    ///   - target: target instance.
    ///   - identifiers: list of identifiers.
    fileprivate func generateTargetReferences(_ target: PBXTarget,
                                              identifiers: [String]) throws {
        var identifiers = identifiers
        identifiers.append(target.name)

        // Configuration list
        if let configurationList = target.buildConfigurationList {
            try generateConfigurationListReferences(configurationList,
                                                    identifiers: identifiers)
        }

        // Build phases
        let buildPhases: [PBXBuildPhase] = target.buildPhaseReferences.objects()
        try buildPhases.forEach({ try generateBuildPhaseReferences($0,
                                                                   identifiers: identifiers) })

        // Build rules
        let buildRules: [PBXBuildRule] = target.buildRuleReferences.objects()
        try buildRules.forEach({ try generateBuildRules($0, identifiers: identifiers) })

        // Dependencies
        let dependencies: [PBXTargetDependency] = target.dependencyReferences.objects()
        try dependencies.forEach({ try generateTargetDependencyReferences($0, identifiers: identifiers) })
    }

    /// Generates the reference for a target dependency object.
    ///
    /// - Parameters:
    ///   - targetDependency: target dependency instance.
    ///   - identifiers: list of identifiers.
    fileprivate func generateTargetDependencyReferences(_ targetDependency: PBXTargetDependency,
                                                        identifiers: [String]) throws {
        var identifiers = identifiers

        // Target proxy
        if let targetProxyReference = targetDependency.targetProxyReference,
            targetProxyReference.temporary,
            let targetProxy = targetDependency.targetProxy,
            let remoteGlobalIDReference = targetProxy.remoteGlobalIDReference {
            var identifiers = identifiers
            identifiers.append(remoteGlobalIDReference.value)
            targetProxy.fixReference(identifiers: identifiers)
        }

        // Target dependency
        if targetDependency.reference.temporary {
            if let targetReference = targetDependency.targetReference?.value {
                identifiers.append(targetReference)
            }
            if let targetProxyReference = targetDependency.targetProxyReference?.value {
                identifiers.append(targetProxyReference)
            }
            targetDependency.fixReference(identifiers: identifiers)
        }
    }

    /// Generates the reference for a build phase object.
    ///
    /// - Parameters:
    ///   - buildPhase: build phase instance.
    ///   - identifiers: list of identifiers.
    fileprivate func generateBuildPhaseReferences(_ buildPhase: PBXBuildPhase,
                                                  identifiers: [String]) throws {
        var identifiers = identifiers
        if let name = buildPhase.name() {
            identifiers.append(name)
        }

        // Build phase
        buildPhase.fixReference(identifiers: identifiers)

        // Build files
        buildPhase.fileReferences.forEach { buildFileReference in
            if !buildFileReference.temporary { return }

            guard let buildFile: PBXBuildFile = buildFileReference.object() else { return }

            var identifiers = identifiers

            if let fileReference = buildFile.fileReference,
                let fileReferenceObject: PBXObject = fileReference.object() {
                identifiers.append(fileReferenceObject.reference.value)
            }

            buildFile.fixReference(identifiers: identifiers)
        }
    }

    /// Generates the reference for a build rule object.
    ///
    /// - Parameters:
    ///   - buildRule: build phase instance.
    ///   - identifiers: list of identifiers.
    fileprivate func generateBuildRules(_ buildRule: PBXBuildRule,
                                        identifiers: [String]) throws {
        var identifiers = identifiers
        if let name = buildRule.name {
            identifiers.append(name)
        }

        // Build rule
        buildRule.fixReference(identifiers: identifiers)
    }
}

extension PBXObject {

    /// Given a list of identifiers, it generates a deterministic reference.
    ///
    /// - Parameter identifiers: list of identifiers used to generate the reference of the object.
    /// - Returns: object reference.
    func fixReference(identifiers: [String]) {
        if reference.temporary {
            let identifiers = [String(describing: type(of: self))] + identifiers
            let value = identifiers.joined(separator: "-").md5.uppercased()
            reference.fix(value)
        }
    }
}
