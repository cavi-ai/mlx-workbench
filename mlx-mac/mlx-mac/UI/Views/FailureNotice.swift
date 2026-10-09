import SwiftUI

/// A failure as one tinted line (the error's first line, two lines at most); the full text opens in a popover.
/// Compare's lane headers and result cells and Activity's rows render failures through this view.
struct FailureNotice: View {
    enum DetailsPolicy {
        /// Details is always offered.
        case always
        /// Details is offered only when the full text says more than the line.
        case whenDifferent
    }

    let error: String
    var details: DetailsPolicy = .always
    @State private var showsDetails = false

    private var line: String { ComparePresentation.firstLine(of: error) }

    private var offersDetails: Bool {
        switch details {
        case .always: return true
        case .whenDifferent: return error.trimmingCharacters(in: .whitespacesAndNewlines) != line
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.xxs) {
            Label(line, systemImage: "exclamationmark.triangle.fill")
                .font(WorkbenchTypography.secondary)
                .foregroundStyle(WorkbenchColor.failure)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            if offersDetails {
                Button("Details") { showsDetails = true }
                    .buttonStyle(.borderless)
                    .font(WorkbenchTypography.secondary)
                    .popover(isPresented: $showsDetails) {
                        ScrollView {
                            Text(error)
                                .font(WorkbenchTypography.secondary)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(WorkbenchSpacing.sm)
                        }
                        .frame(width: WorkbenchSize.detailsPopoverWidth)
                        .frame(maxHeight: WorkbenchSize.detailsPopoverWidth)
                    }
            }
        }
    }
}
