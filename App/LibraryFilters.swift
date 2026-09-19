import SwiftUI
import Domain
import Input
import Focus

enum FilterChoice: Equatable {
    case sort(LibrarySort), installation(InstallationFilter), genre(String?), source(String?)
    case controller(ControllerSupport?), compatibility(Compatibility?), moreGenres, reset
    var title: String {
        switch self {
        case .sort(let sort): sort.title
        case .installation(let value): value.rawValue
        case .genre(let value): value ?? "Any"
        case .source(let value): value?.capitalized ?? "Any"
        case .controller(let value): value?.rawValue.capitalized ?? "Any"
        case .compatibility(let value): value?.rawValue ?? "Any"
        case .moreGenres: "More…"
        case .reset: "Reset"
        }
    }
    var statusColor: Color? {
        guard case .compatibility(let value) = self, let value else { return nil }
        return switch value { case .untested: Design.muted; case .works: Design.green; case .playable: Design.amber; case .broken: Design.red }
    }
}
struct FilterChip: Identifiable {
    let id: Int
    let choice: FilterChoice
    let frame: CGRect
}
struct FilterHeading: Identifiable { let id: Int; let title: String; let top: Double }
struct FilterLayout { let chips: [FilterChip]; let headings: [FilterHeading]; let height: Double }

extension LibraryModel {
    var filterLayout: FilterLayout {
        var genres = Set(games.flatMap(\.genres))
        if let selected = refinements.genre { genres.insert(selected) }
        let allGenres = genres.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        let commonGenres = ["Action", "Adventure", "RPG", "Strategy", "Puzzle"].compactMap { title in
            allGenres.first { $0.localizedCaseInsensitiveCompare(title) == .orderedSame }
        }
        let orderedGenres = commonGenres + allGenres.filter { !commonGenres.contains($0) }
        var shownGenres = expandedGenres ? orderedGenres : Array(orderedGenres.prefix(5))
        if !expandedGenres, let selected = refinements.genre, !shownGenres.contains(selected) {
            if shownGenres.count == 5 { shownGenres.removeLast() }
            shownGenres.append(selected)
        }
        var groups: [(String, [FilterChoice])] = [
            ("Sort by", LibrarySort.allCases.map(FilterChoice.sort)),
            ("Installed", InstallationFilter.allCases.map(FilterChoice.installation))
        ]
        var sources = Set(games.map { $0.id.source })
        if let selected = refinements.source { sources.insert(selected) }
        if sources.count > 1 || refinements.source != nil { groups.append(("Source", [.source(nil)] + sources.sorted().map { .source($0) })) }
        groups += [
            ("Genre", [.genre(nil)] + shownGenres.map { .genre($0) } + (!expandedGenres && allGenres.count > 5 ? [.moreGenres] : [])),
            ("Controller support", [.controller(nil)] + [ControllerSupport.full, .partial, .none, .unknown].map { .controller($0) }),
            ("Compatibility", [.compatibility(nil)] + [Compatibility.works, .playable, .broken, .untested].map { .compatibility($0) })
        ]
        var chips: [FilterChip] = [], headings: [FilterHeading] = [], y = 12.0
        let font = NSFont(name: "Barlow-Medium", size: 24) ?? NSFont.systemFont(ofSize: 24)
        for (title, choices) in groups {
            headings.append(.init(id: headings.count, title: title, top: y))
            y += 38
            var x = 12.0
            for choice in choices {
                let measured = (choice.title as NSString).size(withAttributes: [.font: font]).width
                let width = min(520, ceil(measured) + 40 + (choice.statusColor == nil ? 0 : 22))
                if x > 12 && x + width > 532 { x = 12; y += 66 }
                chips.append(.init(id: chips.count, choice: choice, frame: CGRect(x: x, y: y, width: width, height: 54)))
                x += width + 12
            }
            y += 90
        }
        return FilterLayout(chips: chips, headings: headings, height: y - 24)
    }
    func filterIsSelected(_ choice: FilterChoice) -> Bool {
        switch choice {
        case .sort(let value): sort == value
        case .installation(let value): refinements.installation == value
        case .genre(let value): refinements.genre == value
        case .source(let value): refinements.source == value
        case .controller(let value): refinements.controller == value
        case .compatibility(let value): refinements.compatibility == value
        default: false
        }
    }
    func activateFilter(_ choice: FilterChoice) {
        switch choice {
        case .sort(let value): sort = value
        case .installation(let value): refinements.installation = value
        case .genre(let value): refinements.genre = value
        case .source(let value): refinements.source = value
        case .controller(let value): refinements.controller = value
        case .compatibility(let value): refinements.compatibility = value
        case .moreGenres: expandedGenres = true
        case .reset: refinements = .init(); sort = .name; filterChoiceIndex = 0; filterScrollOffset = 0
        }
        revealFilterFocus()
    }
    func performFilters(_ action: InputAction) {
        switch action {
        case .back, .options: panel = nil
        case .favorite: activateFilter(.reset)
        case .confirm: activateFilter(filterLayout.chips[safe: filterChoiceIndex]?.choice ?? .reset)
        case .move(let direction): moveFilterFocus(direction)
        case .nextPage: for _ in 0..<3 { moveFilterFocus(.down) }
        case .previousPage: for _ in 0..<3 { moveFilterFocus(.up) }
        default: break
        }
    }
    private func moveFilterFocus(_ direction: Direction) {
        let layout = filterLayout
        let reset = FilterChip(id: layout.chips.count, choice: .reset, frame: CGRect(x: 400, y: layout.height + 24, width: 120, height: 54))
        let chips = layout.chips + [reset]
        guard let current = chips[safe: filterChoiceIndex] else { filterChoiceIndex = 0; return }
        let candidates = chips.filter { item in
            switch direction {
            case .left: abs(item.frame.minY - current.frame.minY) < 1 && item.frame.midX < current.frame.midX
            case .right: abs(item.frame.minY - current.frame.minY) < 1 && item.frame.midX > current.frame.midX
            case .up: item.frame.minY < current.frame.minY
            case .down: item.frame.minY > current.frame.minY
            }
        }
        let next = candidates.min {
            let a = abs($0.frame.midY - current.frame.midY), b = abs($1.frame.midY - current.frame.midY)
            if a != b { return a < b }
            return abs($0.frame.midX - current.frame.midX) < abs($1.frame.midX - current.frame.midX)
        }
        if let next { filterChoiceIndex = next.id; revealFilterFocus() }
    }
    func revealFilterFocus() {
        let layout = filterLayout
        guard let chip = layout.chips[safe: filterChoiceIndex] else { return }
        let heading = layout.headings.last { $0.top < chip.frame.minY }
        let top = chip.frame.minY - (chip.frame.minY - (heading?.top ?? 0) < 40 ? 38 : 0)
        filterScrollOffset = FocusViewport.reveal(offset: filterScrollOffset, itemMin: top,
            itemMax: chip.frame.maxY, viewport: 760, content: layout.height, margin: 12)
    }
}

struct LibraryFilterSheet: View {
    @Bindable var model: LibraryModel
    var body: some View {
        let layout = model.filterLayout
        VStack(alignment: .leading, spacing: 24) {
            ZStack(alignment: .topLeading) {
                ForEach(layout.headings) { heading in
                    SectionLabel(text: heading.title).offset(x: 12, y: heading.top - model.filterScrollOffset)
                }
                ForEach(layout.chips) { chip in
                    Button { model.filterChoiceIndex = chip.id; model.activateFilter(chip.choice) } label: {
                        HStack(spacing: 10) {
                            if let color = chip.choice.statusColor { Circle().fill(color).frame(width: 10, height: 10) }
                            Text(chip.choice.title).lineLimit(1)
                        }.font(Design.body(24, weight: "Medium"))
                            .foregroundStyle(model.filterIsSelected(chip.choice) && chip.choice.title != "Any" ? Design.background : Design.text)
                            .frame(width: chip.frame.width, height: 54)
                            .background(model.filterIsSelected(chip.choice) ? chip.choice.title == "Any" ? Design.text.opacity(0.14) : Design.accent : .clear, in: RoundedRectangle(cornerRadius: 8))
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(model.filterIsSelected(chip.choice) ? .clear : Design.text.opacity(0.2), lineWidth: 2))
                            .focusRing(model.filterChoiceIndex == chip.id, compact: true)
                    }.buttonStyle(.plain).offset(x: chip.frame.minX, y: chip.frame.minY - model.filterScrollOffset)
                }
            }.frame(width: 544, height: 760, alignment: .topLeading).clipped()
                .animation(model.reducedMotion ? nil : .easeOut(duration: 0.18), value: model.filterScrollOffset)
                .padding(.leading, -12)
            HStack {
                Text("\(model.filteredGames.count) games match").font(Design.body(24)).foregroundStyle(Design.secondary)
                Spacer()
                Button { model.activateFilter(.reset) } label: {
                    Text("Reset").font(Design.body(24, weight: "Medium")).padding(.horizontal, 20).frame(height: 54)
                        .background(Design.text.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                        .focusRing(model.filterChoiceIndex == layout.chips.count, compact: true)
                }.buttonStyle(.plain)
            }
            LegendItem(glyph: model.controllerName == nil || model.keyboardNavigation ? "ESC" : model.controllerBackGlyph, title: "Close")
        }.padding(.horizontal, 60).padding(.top, 138).padding(.bottom, 40)
            .frame(width: 640, height: 1080, alignment: .topLeading).background(Design.panel)
            .overlay(alignment: .leading) { Rectangle().fill(Design.text.opacity(0.12)).frame(width: 1) }
            .shadow(color: .black.opacity(0.5), radius: 40, x: -20)
    }
}
