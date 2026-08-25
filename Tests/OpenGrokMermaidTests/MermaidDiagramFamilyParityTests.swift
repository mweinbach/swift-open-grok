import Foundation
import Testing

@testable import OpenGrokMermaid

@Suite("Mermaid class diagram upstream parity")
struct MermaidClassDiagramParityTests {
    @Test("class compartments, stereotypes and inheritance survive SVG rendering")
    func classCompartmentsAndInheritance() throws {
        let source = """
            classDiagram
              class Animal {
                <<abstract>>
                +int age
                +isMammal() bool
                +mate()
              }
              class Duck {
                +String beakColor
                +swim()
              }
              Animal <|-- Duck
              Animal <|-- Fish
              Duck *-- Bill
              Duck ..> Pond : swims in
            """
        let diagram = try MermaidRenderer.parse(source)
        guard case let .classDiagram(details)? = diagram.details else {
            Issue.record("class diagram metadata did not reach the renderer")
            return
        }
        let animal = try #require(details.classes.first { $0.id == "Animal" })
        #expect(animal.annotation == "abstract")
        #expect(animal.attributes == ["+int age"])
        #expect(animal.methods == ["+isMammal() bool", "+mate()"])
        #expect(details.relationships.count == 4)
        #expect(details.relationships.map(\.kind) == [.inheritance, .inheritance, .composition, .dashedDependency])

        let layout = MermaidRenderer.layout(diagram)
        #expect(layout.nodes.count == 5)
        #expect(layout.edges.count == 4)
        #expect(layout.node(id: "Animal")?.label.contains("«abstract»") == true)
        #expect(layout.node(id: "Animal")?.label.contains("────────") == true)

        let svg = MermaidRenderer.svg(layout, diagram: diagram)
        for expected in ["Animal", "+int age", "+isMammal() bool", "Duck", "Fish", "Bill", "Pond", "swims in", "△", "◆"] {
            #expect(svg.contains(expected), "missing class diagram content: \(expected)")
        }
        #expect(svg.contains("stroke-dasharray=\"3 3\""))
    }

    @Test("generic names, inline members, cardinality and directions remain meaningful")
    func genericMembersCardinalityAndDirection() throws {
        let diagram = try MermaidRenderer.parse(
            """
            classDiagram-v2
              direction LR
              <<interface>> Shape~T~
              Shape~T~ : +area() T
              Student "many" --> "1" Shape~T~ : attends
              School o-- Student
            """
        )
        guard case let .classDiagram(details)? = diagram.details else {
            Issue.record("class metadata absent")
            return
        }
        let shape = try #require(details.classes.first { $0.id == "Shape~T~" })
        #expect(shape.annotation == "interface")
        #expect(shape.methods == ["+area() T"])
        #expect(details.direction == .leftToRight)

        let dependency = try #require(details.relationships.first)
        #expect(dependency.sourceCardinality == "many")
        #expect(dependency.targetCardinality == "1")
        #expect(dependency.label == "attends")

        let layout = MermaidRenderer.layout(diagram)
        #expect(layout.edges.contains { $0.label == "many attends 1" })
        #expect(layout.node(id: "Shape~T~")?.label.contains("Shape<T>") == true)
        #expect(try MermaidRenderer.render("classDiagram\n A o-- B").contains("◇"))
    }

    @Test("unknown statements and incomplete blocks fail visibly")
    func malformedClassDiagrams() {
        for source in [
            "classDiagram",
            "classDiagram\n A --> B\n total garbage here",
            "classDiagram\n class Broken {\n +field",
            "classDiagram\n A -->",
        ] {
            #expect(throws: MermaidError.self) { try MermaidRenderer.render(source) }
        }
    }

    @Test("class member compartments are bounded with a visible ellipsis")
    func boundedClassMembers() throws {
        let members = (0..<12).map { " +field\($0)" }.joined(separator: "\n")
        let diagram = try MermaidRenderer.parse("classDiagram\n class Big {\n\(members)\n }")
        let label = try #require(MermaidRenderer.layout(diagram).node(id: "Big")?.label)
        #expect(label.contains("+field7"))
        #expect(!label.contains("+field9"))
        #expect(label.contains("…"))
    }
}

@Suite("Mermaid entity relationship diagram upstream parity")
struct MermaidEntityRelationshipDiagramParityTests {
    @Test("entity fields, keys and identifying cardinality reach the final SVG")
    func entitiesAttributesAndRelationships() throws {
        let source = """
            erDiagram
              CUSTOMER ||--o{ ORDER : places
              ORDER ||--|{ LINE_ITEM : contains
              PRODUCT }o..o{ LINE_ITEM : "is in"
              CUSTOMER {
                string name PK "full name"
                int custNumber
              }
              ORDER {
                int orderNumber
                date placed
              }
            """
        let diagram = try MermaidRenderer.parse(source)
        guard case let .entityRelationshipDiagram(details)? = diagram.details else {
            Issue.record("entity relationship metadata did not reach the renderer")
            return
        }
        #expect(details.entities.map(\.id) == ["CUSTOMER", "ORDER", "LINE_ITEM", "PRODUCT"])
        #expect(details.relationships.count == 3)
        #expect(details.relationships[0].sourceCardinality == .exactlyOne)
        #expect(details.relationships[0].targetCardinality == .zeroOrMore)
        #expect(details.relationships[0].isIdentifying)
        #expect(!details.relationships[2].isIdentifying)

        let customer = try #require(details.entities.first { $0.id == "CUSTOMER" })
        #expect(customer.attributes[0].type == "string")
        #expect(customer.attributes[0].name == "name")
        #expect(customer.attributes[0].key == "PK")

        let svg = try MermaidRenderer.render(source)
        for expected in ["CUSTOMER", "ORDER", "LINE_ITEM", "PRODUCT", "string name PK", "int custNumber", "1 places 0..*", "1 contains 1..*", "0..* is in 0..*"] {
            #expect(svg.contains(expected), "missing entity relationship content: \(expected)")
        }
        #expect(!svg.contains("full name"))
        #expect(svg.contains("stroke-dasharray=\"3 3\""))
    }

    @Test("entity aliases and every cardinality remain visible")
    func aliasesAndCardinality() throws {
        let diagram = try MermaidRenderer.parse(
            """
            erDiagram
              p[Person] ||--o{ a["Bank Account"] : owns
              a |o--o| AUDIT : checked
              AUDIT }|--|{ EVENT : records
            """
        )
        let layout = MermaidRenderer.layout(diagram)
        #expect(layout.node(id: "p")?.label == "Person")
        #expect(layout.node(id: "a")?.label == "Bank Account")
        #expect(layout.edges.map(\.label) == ["1 owns 0..*", "0..1 checked 0..1", "1..* records 1..*"])
        #expect(layout.edges.allSatisfy { $0.style == .line })
    }

    @Test("malformed operators and orphaned entity blocks remain parse errors")
    func malformedEntityRelationshipDiagrams() {
        for source in [
            "erDiagram",
            "erDiagram\n A ||==o{ B : broken",
            "erDiagram\n A ||--|| B : ok\n utter nonsense statement",
            "erDiagram\n CUSTOMER {\n string name",
            "erDiagram\n CUSTOMER {\n missingType\n }",
        ] {
            #expect(throws: MermaidError.self) { try MermaidRenderer.render(source) }
        }
    }
}

@Suite("Mermaid sequence diagram upstream parity")
struct MermaidSequenceDiagramParityTests {
    @Test("participant order, aliases, replies and lifelines have chronological geometry")
    func participantOrderAndChronologicalMessages() throws {
        let diagram = try MermaidRenderer.parse(
            """
            sequenceDiagram
              participant B as Backend
              actor A as Alice
              A->>B: Hello Bob
              B-->>A: Hi Alice
            """
        )
        guard case let .sequenceDiagram(details)? = diagram.details else {
            Issue.record("sequence metadata did not reach the renderer")
            return
        }
        #expect(details.participants.map(\.id) == ["B", "A"])
        #expect(details.participants.map(\.label) == ["Backend", "Alice"])
        #expect(details.participants[1].isActor)

        let layout = MermaidRenderer.layout(diagram)
        let backend = try #require(layout.node(id: "B"))
        let alice = try #require(layout.node(id: "A"))
        #expect(backend.x < alice.x)
        #expect(backend.y == alice.y)
        #expect((layout.node(id: "__sequence_footer_B")?.y ?? 0) > backend.y)

        let messages = layout.edges.filter { $0.label != nil }
        #expect(messages.map(\.label) == ["Hello Bob", "Hi Alice"])
        #expect(messages[0].points[0].y < messages[1].points[0].y)
        #expect(messages[0].points[0].x > messages[0].points[1].x)
        #expect(messages[1].style == .dottedArrow)
        #expect(layout.edges.filter { $0.style == .dottedLine }.count == 2)

        let svg = MermaidRenderer.svg(layout, diagram: diagram)
        #expect(svg.components(separatedBy: ">Backend<").count == 3)
        #expect(svg.contains("Hello Bob"))
        #expect(svg.contains("Hi Alice"))
        #expect(svg.contains("stroke-dasharray=\"3 3\""))
    }

    @Test("notes, autonumbering, visible blocks, self messages and cross heads survive")
    func notesBlocksAndSelfMessages() throws {
        let diagram = try MermaidRenderer.parse(
            """
            sequenceDiagram
              autonumber
              participant C as Client
              participant S as Server
              C->>S: GET /api/items
              S-->>C: 200 OK
              C->>C: render list
              Note over C,S: happy path
              loop retry x3
                C-x S: timeout
              end
            """
        )
        guard case let .sequenceDiagram(details)? = diagram.details else {
            Issue.record("sequence metadata absent")
            return
        }
        let messages = details.events.compactMap { event -> MermaidSequenceMessage? in
            if case let .message(message) = event { return message }
            return nil
        }
        #expect(messages.map(\.text) == ["1. GET /api/items", "2. 200 OK", "3. render list", "4. timeout"])
        #expect(messages[3].isCross)

        let layout = MermaidRenderer.layout(diagram)
        let loop = try #require(layout.edges.first { $0.from == "C" && $0.to == "C" })
        #expect(loop.points.count == 4)
        #expect(loop.points[1].x > loop.points[0].x)
        #expect(layout.nodes.contains { $0.label == "happy path" })
        #expect(layout.edges.contains { $0.label == "loop retry x3" })
        #expect(layout.edges.contains { $0.label == "end" })
        #expect(layout.edges.contains { $0.label == "4. timeout ×" })

        let svg = MermaidRenderer.svg(layout, diagram: diagram)
        for expected in ["Client", "Server", "1. GET /api/items", "2. 200 OK", "3. render list", "happy path", "loop retry x3", "4. timeout ×"] {
            #expect(svg.contains(expected), "missing sequence content: \(expected)")
        }
    }

    @Test("notes outside the first lifeline stay inside the canvas")
    func leftNotesFitCanvas() throws {
        let diagram = try MermaidRenderer.parse(
            """
            sequenceDiagram
              Alice->>Bob: hello
              Note left of Alice: a note outside the first lifeline
              Note right of Bob: a note outside the last lifeline
            """
        )
        let layout = MermaidRenderer.layout(diagram)
        for node in layout.nodes {
            #expect(node.x - node.width / 2 >= 0)
            #expect(node.x + node.width / 2 <= layout.width)
        }
    }

    @Test("empty, malformed and unterminated sequence input fails visibly")
    func malformedSequenceDiagrams() {
        for source in [
            "sequenceDiagram",
            "sequenceDiagram\n ->>Bob: orphan",
            "sequenceDiagram\n Alice->>Bob: hi\n garbage statement here",
            "sequenceDiagram\n Alice->>Bob: hi\n loop retry",
            "sequenceDiagram\n Alice->>Bob: hi\n Note over : missing anchor",
            "sequenceDiagram\n end",
        ] {
            #expect(throws: MermaidError.self) { try MermaidRenderer.render(source) }
        }
    }

    @Test("participant and event caps reject oversized diagrams without truncating silently")
    func oversizedSequenceDiagrams() {
        let participants = (0...128).map { "participant P\($0)" }.joined(separator: "\n")
        #expect(throws: MermaidError.self) {
            try MermaidRenderer.parse("sequenceDiagram\n\(participants)")
        }

        let messages = Array(repeating: "A->>B: again", count: 513).joined(separator: "\n")
        #expect(throws: MermaidError.self) {
            try MermaidRenderer.parse("sequenceDiagram\n\(messages)")
        }
    }

    @Test("quoted semicolons, comments and CRLF delimiters preserve the source grammar")
    func sourceLexingParity() throws {
        let diagram = try MermaidRenderer.parse(
            "sequenceDiagram\r\n%% hidden\r\nparticipant A as \"Alice; A\"\r\nA->>B: hello %% ignored"
        )
        guard case let .sequenceDiagram(details)? = diagram.details else {
            Issue.record("sequence metadata absent")
            return
        }
        #expect(details.participants.first?.label == "Alice; A")
        let message = try #require(details.events.first)
        guard case let .message(value) = message else {
            Issue.record("message absent")
            return
        }
        #expect(value.text == "hello")
    }
}

@Suite("Additional Mermaid family renderer invariants")
struct MermaidAdditionalDiagramFamilyInvariantTests {
    @Test("class, entity relationship and sequence rendering remains deterministic")
    func deterministicAdditionalFamilies() throws {
        for source in [
            MermaidSamples.classDiagram,
            MermaidSamples.entityRelationshipDiagram,
            MermaidSamples.sequenceDiagram,
        ] {
            let first = try MermaidRenderer.render(source)
            let second = try MermaidRenderer.render(source)
            #expect(first == second)
        }
    }

    @Test("overlarge sources fail closed before diagram parsing")
    func sourceSizeCap() {
        let oversizedComment = String(repeating: "a", count: 1_048_577)
        #expect(throws: MermaidError.self) {
            try MermaidRenderer.parse("classDiagram\n%% \(oversizedComment)")
        }
    }
}
