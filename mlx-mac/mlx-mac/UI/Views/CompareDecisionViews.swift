import SwiftUI

/// One lane's graded answers for one prompt. Probabilities are the model's reported values.
struct DecisionAnswersView: View {
    let evidence: DecisionEvidence
    let questions: [DecisionQuestion]

    var body: some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.xs) {
            ForEach(evidence.grades, id: \.question) { grade in
                let question = questions.first { $0.name == grade.question }
                HStack(alignment: .firstTextBaseline, spacing: WorkbenchSpacing.xs) {
                    Image(systemName: Self.symbol(grade))
                        .foregroundStyle(grade.correct == false ? WorkbenchColor.warning : grade.correct == true ? WorkbenchColor.success : WorkbenchColor.muted)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 0) {
                        Text("\(grade.question): \(Self.answer(grade, question))")
                            .font(WorkbenchTypography.secondary.monospacedDigit())
                            .fixedSize(horizontal: false, vertical: true)
                        if let detail = Self.detail(grade, question) {
                            Text(detail).font(WorkbenchTypography.metadata.monospacedDigit()).foregroundStyle(WorkbenchColor.muted)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(Self.accessibilityLabel(grade, question))
            }
        }
    }

    static func symbol(_ grade: DecisionGrade) -> String {
        switch grade.correct {
        case true?: "checkmark.circle"
        case false?: "xmark.circle"
        case nil: "circle.dashed"
        }
    }

    static func answer(_ grade: DecisionGrade, _ question: DecisionQuestion?) -> String {
        guard let answer = grade.answer else { return "No answer" }
        let title = question?.answerTitle(answer) ?? answer
        return grade.probability.map { String(format: "%@ · p %.2f", title, $0) } ?? title
    }

    static func detail(_ grade: DecisionGrade, _ question: DecisionQuestion?) -> String? {
        var parts: [String] = []
        if let score = grade.score { parts.append(String(format: "expected level %.2f", score)) }
        if grade.correct == false, let expected = grade.expected {
            let title = question?.answerTitle(expected) ?? expected
            parts.append(grade.expectedProbability.map { String(format: "expected %@ · p %.2f", title, $0) } ?? "expected \(title)")
        }
        if grade.correct == nil { parts.append("not scored") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    static func accessibilityLabel(_ grade: DecisionGrade, _ question: DecisionQuestion?) -> String {
        let verdict = grade.correct.map { $0 ? "correct" : "incorrect" } ?? "not scored"
        return "\(grade.question): \(answer(grade, question)), \(verdict)" + (detail(grade, question).map { ", \($0)" } ?? "")
    }
}

/// The questions a classification prompt asks, with the answer that counts as correct.
struct DecisionQuestionsSummary: View {
    let questions: [DecisionQuestion]

    var body: some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.xxs) {
            ForEach(questions) { question in
                Text("\(question.name) · \(question.kind.title) · \(question.expectedTitle.map { "expected \($0)" } ?? "not scored")")
                    .font(WorkbenchTypography.metadata).foregroundStyle(WorkbenchColor.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .help(question.instructions)
            }
        }
    }
}

/// Typed questions for one classification prompt. Editing never runs a model.
struct DecisionQuestionsEditor: View {
    @Binding var questions: [DecisionQuestion]
    let promptNumber: Int

    var body: some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.sm) {
            Text("Questions").font(WorkbenchTypography.label)
            ForEach(questions.indices, id: \.self) { index in
                DecisionQuestionCard(question: question(at: index), promptNumber: promptNumber, number: index + 1,
                                     canRemove: questions.count > 1) {
                    if questions.indices.contains(index) { questions.remove(at: index) }
                }
            }
            Button("Add question", systemImage: "plus") {
                questions.append(DecisionQuestion(name: Self.unusedName(in: questions), kind: .choice, instructions: "",
                                                  options: [.init(label: ""), .init(label: "")]))
            }
            .disabled(questions.count >= DecisionQuestion.maximumQuestions)
            .accessibilityLabel("Add question to prompt \(promptNumber)")
        }
    }

    /// Rows can be evaluated once more after a removal; a stale index reads a placeholder and writes nothing.
    private func question(at index: Int) -> Binding<DecisionQuestion> {
        Binding(get: { questions.indices.contains(index) ? questions[index] : DecisionQuestion(name: "", kind: .noul, instructions: "") },
                set: { if questions.indices.contains(index) { questions[index] = $0 } })
    }

    static func unusedName(in questions: [DecisionQuestion]) -> String {
        let names = Set(questions.map(\.name))
        return (1...).lazy.map { "question\($0)" }.first { !names.contains($0) }!
    }
}

private struct DecisionQuestionCard: View {
    @Binding var question: DecisionQuestion
    let promptNumber: Int
    let number: Int
    let canRemove: Bool
    let onRemove: () -> Void

    private var label: String { "Prompt \(promptNumber) question \(number)" }

    var body: some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.xs) {
            HStack(alignment: .firstTextBaseline, spacing: WorkbenchSpacing.sm) {
                TextField("Name", text: $question.name).frame(maxWidth: 180).accessibilityLabel("\(label) name")
                Picker("Type", selection: kind) {
                    ForEach(DecisionQuestion.Kind.allCases) { Text($0.title).tag($0) }
                }.labelsHidden().fixedSize().accessibilityLabel("\(label) type")
                Spacer()
                Button(role: .destructive, action: onRemove) { Label("Remove question", systemImage: "minus.circle") }
                    .labelStyle(.iconOnly).buttonStyle(.borderless).disabled(!canRemove)
                    .accessibilityLabel("Remove \(label.lowercased())")
            }
            TextField("Instructions", text: $question.instructions, axis: .vertical).lineLimit(1...3)
                .accessibilityLabel("\(label) instructions")
            switch question.kind {
            case .choice, .score:
                ForEach(question.options.indices, id: \.self) { index in
                    HStack(spacing: WorkbenchSpacing.xs) {
                        if question.kind == .score {
                            Text("\(index)").font(WorkbenchTypography.metadata.monospacedDigit()).foregroundStyle(WorkbenchColor.muted)
                        }
                        TextField(question.kind == .choice ? "Label" : "Level description", text: optionLabel(index))
                            .accessibilityLabel("\(label) option \(index + 1)")
                        if question.kind == .choice {
                            TextField("Description · optional", text: detail(index))
                                .accessibilityLabel("\(label) option \(index + 1) description")
                        }
                        Button { removeOption(index) } label: { Label("Remove option", systemImage: "minus") }
                            .labelStyle(.iconOnly).buttonStyle(.borderless).disabled(question.options.count <= 2)
                            .accessibilityLabel("Remove \(label.lowercased()) option \(index + 1)")
                    }
                }
                Button(question.kind == .choice ? "Add option" : "Add level", systemImage: "plus") {
                    question.options.append(.init(label: ""))
                }
                .buttonStyle(.borderless).disabled(question.options.count >= DecisionQuestion.maximumOptions)
            case .noul:
                TextField("True means · optional", text: outcome(\.trueText)).accessibilityLabel("\(label) true outcome")
                TextField("False means · optional", text: outcome(\.falseText)).accessibilityLabel("\(label) false outcome")
            }
            Picker("Expected answer", selection: $question.expected) {
                Text("Not scored").tag(String?.none)
                ForEach(expectedChoices, id: \.value) { Text($0.title).tag(Optional($0.value)) }
            }.accessibilityLabel("\(label) expected answer")
        }
        .padding(WorkbenchSpacing.sm)
        .background(WorkbenchColor.canvas, in: RoundedRectangle(cornerRadius: WorkbenchRadius.control))
    }

    private var expectedChoices: [(value: String, title: String)] {
        switch question.kind {
        case .choice: question.options.map(\.label).filter { !$0.isEmpty }.map { ($0, $0) }
        case .score: question.options.indices.map { (String($0), question.answerTitle(String($0))) }
        case .noul: [("true", "True"), ("false", "False")]
        }
    }

    /// Changing type keeps instructions and drops answers the new type cannot use.
    private var kind: Binding<DecisionQuestion.Kind> {
        Binding(get: { question.kind }, set: { kind in
            guard kind != question.kind else { return }
            question.kind = kind
            question.expected = nil
            switch kind {
            case .choice: if question.options.count < 2 { question.options = [.init(label: ""), .init(label: "")] }
            case .score:
                question.options = question.options.map { .init(label: $0.label) }
                if question.options.count < 2 { question.options = [.init(label: ""), .init(label: "")] }
            case .noul: question.options = []
            }
        })
    }

    private func optionLabel(_ index: Int) -> Binding<String> {
        Binding(get: { question.options.indices.contains(index) ? question.options[index].label : "" },
                set: { label in
                    guard question.options.indices.contains(index) else { return }
                    if question.kind == .choice, question.expected == question.options[index].label { question.expected = label.isEmpty ? nil : label }
                    question.options[index].label = label
                })
    }

    private func detail(_ index: Int) -> Binding<String> {
        Binding(get: { question.options.indices.contains(index) ? question.options[index].detail ?? "" : "" },
                set: { if question.options.indices.contains(index) { question.options[index].detail = $0.isEmpty ? nil : $0 } })
    }

    private func outcome(_ path: WritableKeyPath<DecisionQuestion, String?>) -> Binding<String> {
        Binding(get: { question[keyPath: path] ?? "" }, set: { question[keyPath: path] = $0.isEmpty ? nil : $0 })
    }

    private func removeOption(_ index: Int) {
        guard question.options.indices.contains(index) else { return }
        let removed = question.options.remove(at: index)
        if question.kind == .choice, question.expected == removed.label { question.expected = nil }
        if question.kind == .score, let expected = question.expected.flatMap(Int.init), expected >= index {
            question.expected = expected == index ? nil : String(expected - 1)
        }
    }
}
