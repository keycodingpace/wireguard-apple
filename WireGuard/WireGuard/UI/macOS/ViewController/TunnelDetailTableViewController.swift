// SPDX-License-Identifier: MIT
// Copyright © 2018-2019 WireGuard LLC. All Rights Reserved.

import Cocoa

class TunnelDetailTableViewController: NSViewController {

    private enum TableViewModelRow {
        case interfaceFieldRow(TunnelViewModel.InterfaceField)
        case peerFieldRow(peer: TunnelViewModel.PeerData, field: TunnelViewModel.PeerField)
        case onDemandRow
        case spacerRow

        func localizedSectionKeyString() -> String {
            switch self {
            case .interfaceFieldRow: return tr("tunnelSectionTitleInterface")
            case .peerFieldRow: return tr("tunnelSectionTitlePeer")
            case .onDemandRow: return ""
            case .spacerRow: return ""
            }
        }

        func isTitleRow() -> Bool {
            switch self {
            case .interfaceFieldRow(let field): return field == .name
            case .peerFieldRow(_, let field): return field == .publicKey
            case .onDemandRow: return true
            case .spacerRow: return false
            }
        }
    }

    static let interfaceFields: [TunnelViewModel.InterfaceField] = [
        .name, .status, .publicKey, .addresses,
        .listenPort, .mtu, .dns
    ]

    static let peerFields: [TunnelViewModel.PeerField] = [
        .publicKey, .preSharedKey, .endpoint,
        .allowedIPs, .persistentKeepAlive,
        .rxBytes, .txBytes, .lastHandshakeTime
    ]

    let tableView: NSTableView = {
        let tableView = NSTableView()
        tableView.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("TunnelDetail")))
        tableView.headerView = nil
        tableView.rowSizeStyle = .medium
        tableView.backgroundColor = .clear
        tableView.selectionHighlightStyle = .none
        return tableView
    }()

    let statusCheckbox: NSButton = {
        let checkbox = NSButton()
        checkbox.title = ""
        checkbox.setButtonType(.switch)
        checkbox.state = .off
        checkbox.toolTip = "Toggle status (⌘T)"
        return checkbox
    }()

    let editButton: NSButton = {
        let button = NSButton()
        button.title = tr("Edit")
        button.setButtonType(.momentaryPushIn)
        button.bezelStyle = .rounded
        button.toolTip = "Edit tunnel (⌘E)"
        return button
    }()

    let box: NSBox = {
        let box = NSBox()
        box.titlePosition = .noTitle
        box.fillColor = .unemphasizedSelectedContentBackgroundColor
        return box
    }()

    let tunnelsManager: TunnelsManager
    let tunnel: TunnelContainer

    var tunnelViewModel: TunnelViewModel {
        didSet {
            updateTableViewModelRowsBySection()
            updateTableViewModelRows()
        }
    }
    private var tableViewModelRowsBySection = [[(isVisible: Bool, modelRow: TableViewModelRow)]]()
    private var tableViewModelRows = [TableViewModelRow]()

    private var statusObservationToken: AnyObject?
    private var tunnelEditVC: TunnelEditViewController?
    private var reloadRuntimeConfigurationTimer: Timer?

    init(tunnelsManager: TunnelsManager, tunnel: TunnelContainer) {
        self.tunnelsManager = tunnelsManager
        self.tunnel = tunnel
        tunnelViewModel = TunnelViewModel(tunnelConfiguration: tunnel.tunnelConfiguration)
        super.init(nibName: nil, bundle: nil)
        updateTableViewModelRowsBySection()
        updateTableViewModelRows()
        updateStatus()
        statusObservationToken = tunnel.observe(\TunnelContainer.status) { [weak self] _, _ in
            self?.updateStatus()
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        tableView.dataSource = self
        tableView.delegate = self

        statusCheckbox.target = self
        statusCheckbox.action = #selector(statusCheckboxToggled(sender:))

        editButton.target = self
        editButton.action = #selector(handleEditTunnelAction)

        let clipView = NSClipView()
        clipView.documentView = tableView

        let scrollView = NSScrollView()
        scrollView.contentView = clipView // Set contentView before setting drawsBackground
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true

        let containerView = NSView()
        let bottomControlsContainer = NSLayoutGuide()
        containerView.addLayoutGuide(bottomControlsContainer)
        containerView.addSubview(box)
        containerView.addSubview(scrollView)
        containerView.addSubview(statusCheckbox)
        containerView.addSubview(editButton)
        box.translatesAutoresizingMaskIntoConstraints = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        statusCheckbox.translatesAutoresizingMaskIntoConstraints = false
        editButton.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            containerView.topAnchor.constraint(equalTo: scrollView.topAnchor),
            containerView.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor),
            containerView.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor),
            containerView.leadingAnchor.constraint(equalTo: bottomControlsContainer.leadingAnchor),
            containerView.trailingAnchor.constraint(equalTo: bottomControlsContainer.trailingAnchor),
            bottomControlsContainer.heightAnchor.constraint(equalToConstant: 32),
            scrollView.bottomAnchor.constraint(equalTo: bottomControlsContainer.topAnchor),
            bottomControlsContainer.bottomAnchor.constraint(equalTo: containerView.bottomAnchor),
            statusCheckbox.leadingAnchor.constraint(equalTo: bottomControlsContainer.leadingAnchor),
            bottomControlsContainer.bottomAnchor.constraint(equalTo: statusCheckbox.bottomAnchor, constant: 4),
            editButton.trailingAnchor.constraint(equalTo: bottomControlsContainer.trailingAnchor),
            bottomControlsContainer.bottomAnchor.constraint(equalTo: editButton.bottomAnchor, constant: 4)
        ])

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: box.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: box.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: box.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: box.trailingAnchor)
        ])

        NSLayoutConstraint.activate([
            containerView.widthAnchor.constraint(greaterThanOrEqualToConstant: 320),
            containerView.heightAnchor.constraint(greaterThanOrEqualToConstant: 120)
        ])

        view = containerView
    }

    func updateTableViewModelRowsBySection() {
        var modelRowsBySection = [[(isVisible: Bool, modelRow: TableViewModelRow)]]()

        var interfaceSection = [(isVisible: Bool, modelRow: TableViewModelRow)]()
        for field in TunnelDetailTableViewController.interfaceFields {
            let isStatus = field == .status
            let isEmpty = tunnelViewModel.interfaceData[field].isEmpty
            interfaceSection.append((isVisible: isStatus || !isEmpty, modelRow: .interfaceFieldRow(field)))
        }
        interfaceSection.append((isVisible: true, modelRow: .spacerRow))
        modelRowsBySection.append(interfaceSection)

        for peerData in tunnelViewModel.peersData {
            var peerSection = [(isVisible: Bool, modelRow: TableViewModelRow)]()
            for field in TunnelDetailTableViewController.peerFields {
                peerSection.append((isVisible: !peerData[field].isEmpty, modelRow: .peerFieldRow(peer: peerData, field: field)))
            }
            peerSection.append((isVisible: true, modelRow: .spacerRow))
            modelRowsBySection.append(peerSection)
        }

        var onDemandSection = [(isVisible: Bool, modelRow: TableViewModelRow)]()
        onDemandSection.append((isVisible: true, modelRow: .onDemandRow))
        modelRowsBySection.append(onDemandSection)

        tableViewModelRowsBySection = modelRowsBySection
    }

    func updateTableViewModelRows() {
        tableViewModelRows = tableViewModelRowsBySection.flatMap { $0.filter { $0.isVisible }.map { $0.modelRow } }
    }

    func updateStatus() {
        let statusText: String
        switch tunnel.status {
        case .waiting:
            statusText = tr("tunnelStatusWaiting")
        case .inactive:
            statusText = tr("tunnelStatusInactive")
        case .activating:
            statusText = tr("tunnelStatusActivating")
        case .active:
            statusText = tr("tunnelStatusActive")
        case .deactivating:
            statusText = tr("tunnelStatusDeactivating")
        case .reasserting:
            statusText = tr("tunnelStatusReasserting")
        case .restarting:
            statusText = tr("tunnelStatusRestarting")
        }
        statusCheckbox.title = tr(format: "macStatus (%@)", statusText)
        let shouldBeChecked = (tunnel.status != .inactive && tunnel.status != .deactivating)
        let shouldBeEnabled = (tunnel.status == .active || tunnel.status == .inactive)
        statusCheckbox.state = shouldBeChecked ? .on : .off
        statusCheckbox.isEnabled = shouldBeEnabled
        if tunnel.status == .active {
            startUpdatingRuntimeConfiguration()
        } else if tunnel.status == .inactive {
            reloadRuntimeConfiguration()
            stopUpdatingRuntimeConfiguration()
        }
    }

    @objc func handleEditTunnelAction() {
        PrivateDataConfirmation.confirmAccess(to: tr("macViewPrivateData")) { [weak self] in
            guard let self = self else { return }
            let tunnelEditVC = TunnelEditViewController(tunnelsManager: self.tunnelsManager, tunnel: self.tunnel)
            tunnelEditVC.delegate = self
            self.presentAsSheet(tunnelEditVC)
            self.tunnelEditVC = tunnelEditVC
        }
    }

    @objc func handleToggleActiveStatusAction() {
        if tunnel.status == .inactive {
            tunnelsManager.startActivation(of: tunnel)
        } else if tunnel.status == .active {
            tunnelsManager.startDeactivation(of: tunnel)
        }
    }

    @objc func statusCheckboxToggled(sender: AnyObject?) {
        guard let statusCheckbox = sender as? NSButton else { return }
        if statusCheckbox.state == .on {
            tunnelsManager.startActivation(of: tunnel)
        } else if statusCheckbox.state == .off {
            tunnelsManager.startDeactivation(of: tunnel)
        }
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        if let tunnelEditVC = tunnelEditVC {
            dismiss(tunnelEditVC)
        }
        stopUpdatingRuntimeConfiguration()
    }

    func applyTunnelConfiguration(tunnelConfiguration: TunnelConfiguration) {
        // Incorporates changes from tunnelConfiguation. Ignores any changes in peer ordering.

        let tableView = self.tableView

        func handleSectionFieldsModified<T>(fields: [T], modelRowsInSection: [(isVisible: Bool, modelRow: TableViewModelRow)], rowOffset: Int, changes: [T: TunnelViewModel.Changes.FieldChange]) {
            var modifiedRowIndices = IndexSet()
            for (index, field) in fields.enumerated() {
                guard let change = changes[field] else { continue }
                if case .modified(_) = change {
                    let row = modelRowsInSection[0 ..< index].filter { $0.isVisible }.count
                    modifiedRowIndices.insert(rowOffset + row)
                }
            }
            if !modifiedRowIndices.isEmpty {
                tableView.reloadData(forRowIndexes: modifiedRowIndices, columnIndexes: IndexSet(integer: 0))
            }
        }

        func handleSectionFieldsAddedOrRemoved<T>(fields: [T], modelRowsInSection: inout [(isVisible: Bool, modelRow: TableViewModelRow)], rowOffset: Int, changes: [T: TunnelViewModel.Changes.FieldChange]) {
            for (index, field) in fields.enumerated() {
                guard let change = changes[field] else { continue }
                let row = modelRowsInSection[0 ..< index].filter { $0.isVisible }.count
                switch change {
                case .added:
                    tableView.insertRows(at: IndexSet(integer: rowOffset + row), withAnimation: .effectFade)
                    modelRowsInSection[index].isVisible = true
                case .removed:
                    tableView.removeRows(at: IndexSet(integer: rowOffset + row), withAnimation: .effectFade)
                    modelRowsInSection[index].isVisible = false
                case .modified:
                    break
                }
            }
        }

        let changes = self.tunnelViewModel.applyConfiguration(other: tunnelConfiguration)

        if !changes.interfaceChanges.isEmpty {
            handleSectionFieldsModified(fields: TunnelDetailTableViewController.interfaceFields,
                                        modelRowsInSection: self.tableViewModelRowsBySection[0],
                                        rowOffset: 0, changes: changes.interfaceChanges)
        }
        for (peerIndex, peerChanges) in changes.peerChanges {
            let sectionIndex = 1 + peerIndex
            let rowOffset = self.tableViewModelRowsBySection[0 ..< sectionIndex].flatMap { $0.filter { $0.isVisible } }.count
            handleSectionFieldsModified(fields: TunnelDetailTableViewController.peerFields,
                                        modelRowsInSection: self.tableViewModelRowsBySection[sectionIndex],
                                        rowOffset: rowOffset, changes: peerChanges)
        }

        let isAnyInterfaceFieldAddedOrRemoved = changes.interfaceChanges.contains { $0.value == .added || $0.value == .removed }
        let isAnyPeerFieldAddedOrRemoved = changes.peerChanges.contains { $0.changes.contains { $0.value == .added || $0.value == .removed } }

        if isAnyInterfaceFieldAddedOrRemoved || isAnyPeerFieldAddedOrRemoved || !changes.peersRemovedIndices.isEmpty || !changes.peersInsertedIndices.isEmpty {
            tableView.beginUpdates()
            if isAnyInterfaceFieldAddedOrRemoved {
                handleSectionFieldsAddedOrRemoved(fields: TunnelDetailTableViewController.interfaceFields,
                                                  modelRowsInSection: &self.tableViewModelRowsBySection[0],
                                                  rowOffset: 0, changes: changes.interfaceChanges)
            }
            if isAnyPeerFieldAddedOrRemoved {
                for (peerIndex, peerChanges) in changes.peerChanges {
                    let sectionIndex = 1 + peerIndex
                    let rowOffset = self.tableViewModelRowsBySection[0 ..< sectionIndex].flatMap { $0.filter { $0.isVisible } }.count
                    handleSectionFieldsAddedOrRemoved(fields: TunnelDetailTableViewController.peerFields, modelRowsInSection: &self.tableViewModelRowsBySection[sectionIndex], rowOffset: rowOffset, changes: peerChanges)
                }
            }
            if !changes.peersRemovedIndices.isEmpty {
                for peerIndex in changes.peersRemovedIndices {
                    let sectionIndex = 1 + peerIndex
                    let rowOffset = self.tableViewModelRowsBySection[0 ..< sectionIndex].flatMap { $0.filter { $0.isVisible } }.count
                    let count = self.tableViewModelRowsBySection[sectionIndex].filter { $0.isVisible }.count
                    self.tableView.removeRows(at: IndexSet(integersIn: rowOffset ..< rowOffset + count), withAnimation: .effectFade)
                    self.tableViewModelRowsBySection.remove(at: sectionIndex)
                }
            }
            if !changes.peersInsertedIndices.isEmpty {
                for peerIndex in changes.peersInsertedIndices {
                    let peerData = self.tunnelViewModel.peersData[peerIndex]
                    let sectionIndex = 1 + peerIndex
                    let rowOffset = self.tableViewModelRowsBySection[0 ..< sectionIndex].flatMap { $0.filter { $0.isVisible } }.count
                    var modelRowsInSection: [(isVisible: Bool, modelRow: TableViewModelRow)] = TunnelDetailTableViewController.peerFields.map {
                        (isVisible: !peerData[$0].isEmpty, modelRow: .peerFieldRow(peer: peerData, field: $0))
                    }
                    modelRowsInSection.append((isVisible: true, modelRow: .spacerRow))
                    let count = modelRowsInSection.filter { $0.isVisible }.count
                    self.tableView.insertRows(at: IndexSet(integersIn: rowOffset ..< rowOffset + count), withAnimation: .effectFade)
                    self.tableViewModelRowsBySection.insert(modelRowsInSection, at: sectionIndex)
                }
            }
            updateTableViewModelRows()
            tableView.endUpdates()
        }
    }

    private func reloadRuntimeConfiguration() {
        tunnel.getRuntimeTunnelConfiguration { [weak self] tunnelConfiguration in
            guard let tunnelConfiguration = tunnelConfiguration else { return }
            self?.applyTunnelConfiguration(tunnelConfiguration: tunnelConfiguration)
        }
    }

    func startUpdatingRuntimeConfiguration() {
        reloadRuntimeConfiguration()
        reloadRuntimeConfigurationTimer?.invalidate()
        let reloadTimer = Timer(timeInterval: 1 /* second */, repeats: true) { [weak self] _ in
            self?.reloadRuntimeConfiguration()
        }
        reloadRuntimeConfigurationTimer = reloadTimer
        RunLoop.main.add(reloadTimer, forMode: .common)
    }

    func stopUpdatingRuntimeConfiguration() {
        reloadRuntimeConfiguration()
        reloadRuntimeConfigurationTimer?.invalidate()
        reloadRuntimeConfigurationTimer = nil
    }

}

extension TunnelDetailTableViewController: NSTableViewDataSource {
    func numberOfRows(in tableView: NSTableView) -> Int {
        return tableViewModelRows.count
    }
}

extension TunnelDetailTableViewController: NSTableViewDelegate {
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let modelRow = tableViewModelRows[row]
        switch modelRow {
        case .interfaceFieldRow(let field):
            if field == .status {
                return statusCell()
            } else {
                let cell: KeyValueRow = tableView.dequeueReusableCell()
                let localizedKeyString = modelRow.isTitleRow() ? modelRow.localizedSectionKeyString() : field.localizedUIString
                cell.key = tr(format: "macFieldKey (%@)", localizedKeyString)
                cell.value = tunnelViewModel.interfaceData[field]
                cell.isKeyInBold = modelRow.isTitleRow()
                return cell
            }
        case .peerFieldRow(let peerData, let field):
            let cell: KeyValueRow = tableView.dequeueReusableCell()
            let localizedKeyString = modelRow.isTitleRow() ? modelRow.localizedSectionKeyString() : field.localizedUIString
            cell.key = tr(format: "macFieldKey (%@)", localizedKeyString)
            if field == .persistentKeepAlive {
                cell.value = tr(format: "tunnelPeerPersistentKeepaliveValue (%@)", peerData[field])
            } else if field == .preSharedKey {
                cell.value = tr("tunnelPeerPresharedKeyEnabled")
            } else {
                cell.value = peerData[field]
            }
            cell.isKeyInBold = modelRow.isTitleRow()
            return cell
        case .spacerRow:
            return NSView()
        case .onDemandRow:
            let cell: KeyValueRow = tableView.dequeueReusableCell()
            cell.key = tr("macFieldOnDemand")
            cell.value = TunnelViewModel.activateOnDemandDetailText(for: tunnel.activateOnDemandSetting)
            cell.isKeyInBold = true
            return cell
        }
    }

    func statusCell() -> NSView {
        let cell: KeyValueImageRow = tableView.dequeueReusableCell()
        cell.key = tr(format: "macFieldKey (%@)", tr("tunnelInterfaceStatus"))
        cell.value = TunnelDetailTableViewController.localizedStatusDescription(forStatus: tunnel.status)
        cell.valueImage = TunnelDetailTableViewController.image(forStatus: tunnel.status)
        cell.observationToken = tunnel.observe(\.status) { [weak cell] tunnel, _ in
            guard let cell = cell else { return }
            cell.value = TunnelDetailTableViewController.localizedStatusDescription(forStatus: tunnel.status)
            cell.valueImage = TunnelDetailTableViewController.image(forStatus: tunnel.status)
        }
        return cell
    }

    private static func localizedStatusDescription(forStatus status: TunnelStatus) -> String {
        switch status {
        case .inactive:
            return tr("tunnelStatusInactive")
        case .activating:
            return tr("tunnelStatusActivating")
        case .active:
            return tr("tunnelStatusActive")
        case .deactivating:
            return tr("tunnelStatusDeactivating")
        case .reasserting:
            return tr("tunnelStatusReasserting")
        case .restarting:
            return tr("tunnelStatusRestarting")
        case .waiting:
            return tr("tunnelStatusWaiting")
        }
    }

    private static func image(forStatus status: TunnelStatus?) -> NSImage? {
        guard let status = status else { return nil }
        switch status {
        case .active, .restarting, .reasserting:
            return NSImage(named: NSImage.statusAvailableName)
        case .activating, .waiting, .deactivating:
            return NSImage(named: NSImage.statusPartiallyAvailableName)
        case .inactive:
            return NSImage(named: NSImage.statusNoneName)
        }
    }
}

extension TunnelDetailTableViewController: TunnelEditViewControllerDelegate {
    func tunnelSaved(tunnel: TunnelContainer) {
        tunnelViewModel = TunnelViewModel(tunnelConfiguration: tunnel.tunnelConfiguration)
        updateTableViewModelRowsBySection()
        updateTableViewModelRows()
        updateStatus()
        tableView.reloadData()
        self.tunnelEditVC = nil
    }

    func tunnelEditingCancelled() {
        self.tunnelEditVC = nil
    }
}
