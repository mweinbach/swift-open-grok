import OpenGrokShared
import OpenGrokToolTypes

extension BuiltinToolCatalog {
    /// Rust `grok_build/web_run/web_run_description.md` at upstream 00e176c8.
    public static let webRunDescription = #"""
        Tool for accessing the internet.


        ---

        ## Examples of different commands available in this tool

        Examples of different commands available in this tool:
        * `search_query`: {"search_query": [{"q": "What is the capital of France?"}, {"q": "What is the capital of belgium?"}]}. Searches the internet for a given query (and optionally with a domain or recency filter)
        * `image_query`: {"image_query":[{"q": "waterfalls"}]}.
        * `open`: {"open": [{"ref_id": "turn0search0"}, {"ref_id": "https://www.openai.com", "lineno": 120}]}
        * `click`: {"click": [{"ref_id": "turn0fetch3", "id": 17}]}
        * `find`: {"find": [{"ref_id": "turn0fetch3", "pattern": "Annie Case"}]}
        * `screenshot`: {"screenshot": [{"ref_id": "turn1view0", "pageno": 0}, {"ref_id": "turn1view0", "pageno": 3}]}
        * `finance`: {"finance":[{"ticker":"AMD","type":"equity","market":"USA"}]}, {"finance":[{"ticker":"BTC","type":"crypto","market":""}]}
        * `weather`: {"weather":[{"location":"San Francisco, CA"}]}
        * `sports`: {"sports":[{"fn":"standings","league":"nfl"}, {"fn":"schedule","league":"nba","team":"GSW","date_from":"2025-02-24"}]}
        * `time`: {"time":[{"utc_offset":"+03:00"}]}

        ---

        ## Usage hints
        To use this tool efficiently:
        * Use multiple commands and queries in one call to get more results faster; e.g. {"search_query": [{"q": "bitcoin news"}], "finance":[{"ticker":"BTC","type":"crypto","market":""}], "find": [{"ref_id": "turn0search0", "pattern": "Annie Case"}, {"ref_id": "turn0search1", "pattern": "John Smith"}]}
        * Use "response_length" to control the number of results returned by this tool, omit it if you intend to pass "short" in
        * Only write required parameters; do not write empty lists or nulls where they could be omitted.
        * `search_query` must have length at most 4 in each call. If it has length > 3, response_length must be medium or long
        * If you find yourself in a situation where you accidentally call the `web__run` tool, it's best just to send an empty query: {"search_query": [{"q": ""}]}.

        ---

        ## Decision boundary

        If the user makes an explicit request to search the internet, find latest information, look up, etc (or to not do so), you must obey their request.
        When you make an assumption, always consider whether it is temporally stable; i.e. whether there's even a small (>10%) chance it has changed. If it is unstable, you must verify with browsing the internet for verification.

        <situations_where_you_must_browse_the_internet>
        Below is a list of scenarios where browsing the internet MUST be used. PAY CLOSE ATTENTION: you MUST browse the internet in these cases. If you're unsure or on the fence, you MUST bias towards browsing the internet.
        - The information could have changed recently: for example news; prices; laws; schedules; product specs; sports scores; economic indicators; political/public/company figures (e.g. the question relates to 'the president of country A' or 'the CEO of company B', which might change over time); rules; regulations; standards; software libraries that could be updated; exchange rates; recommendations (i.e., recommendations about various topics or things might be informed by what currently exists / is popular / is safe / is unsafe / is in the zeitgeist / etc.); and many many many more categories -- again, if you're on the fence, you MUST browse the internet!
          - For news queries, prioritize more recent events, ensuring you compare publish dates and the date that the event happened.
        - The user is seeking recommendations that could lead them to spend substantial time or money -- researching products, restaurants, travel plans, etc.
        - The user wants (or would benefit from) direct quotes, links, or precise source attribution.
        - A specific page, paper, dataset, PDF, or site is referenced and you haven't been given its contents.
        - You're unsure about a fact, the topic is niche or emerging, or you suspect there's at least a 10% chance you will incorrectly recall it
        - High-stakes accuracy matters (medical, legal, financial guidance). For these you generally should search by default because this information is highly temporally unstable
        - The user explicitly says to search, browse, verify, or look it up.
        </situations_where_you_must_browse_the_internet>

        ---

        ## Citations

        Results from `web__run` include internal reference IDs such as `turn2search5`. Use
        those reference IDs only in calls to `web__run`; do not expose them in the final
        response.

        Cite sources in the final response using Markdown links:

        - Cite a single source as `[descriptive source title](https://example.com/page)`.
        - Cite multiple sources with separate Markdown links, for example
          `[first source](https://example.com/one), [second source](https://example.com/two)`.
        - Link directly to the page that supports the claim. Do not link to search result
          pages or use bare URLs.

        Formatting of citations:

        - Place each citation as near as possible to the claim it supports, normally at
          the end of the sentence or paragraph and after punctuation.
        - Do not place citations inside code fences.
        - Do not put citations on a line by themselves or collect all citations at the
          end of the response.

        If you browse the internet, cite statements supported by web sources. Each cited
        source must directly support the associated claim. Prefer primary and
        authoritative sources, and use sources from different domains when the response
        benefits from multiple perspectives.

        ---

        ## Special cases
        If these conflict with any other instructions, these should take precedence.

        <special_cases>
        - When the user asks for information about how to use OpenAI products, (ChatGPT, the OpenAI API, etc.), you should check the code in local env and only browse as fallback, when you browse restrict your sources to official OpenAI websites using the domains filter, unless otherwise requested.
        - When using search to answer technical questions, you must only rely on primary sources (research papers, official documentation, etc.)
        - Clearly indicate when you are making an inference from sources.
        </special_cases>

        ---

        ## Word limits
        Responses may not excessively quote or draw on a specific source. There are several limits here:
        - **Limit on verbatim quotes:**
          - You may not quote more than 25 words verbatim from any single non-lyrical source, unless the source is reddit.
          - For song lyrics, verbatim quotes must be limited to at most 10 words.
          - Long quotes from reddit are allowed, as long as you indicate that those are direct quotes via a markdown blockquote starting with ">", copy verbatim, and link the source.
        - **Word limits:**
          - Each webpage source in the sources has a word limit label formatted like "[wordlim N]", in which N is the maximum number of words in the whole response that are attributed to that source. If omitted, the word limit is 200 words.
          - Non-contiguous words derived from a given source must be counted to the word limit.
          - The summarization limit N is a maximum for each source.
          - When using multiple sources, their summarization limits add together. However, each article used must be relevant to the response.
        - **Copyright compliance:**
          - You must avoid providing full articles, long verbatim passages, or extensive direct quotes due to copyright concerns.
          - If the user asked for a verbatim quote, the response should provide a short compliant excerpt and then answer with paraphrases and summaries.
          - Again, this limit does not apply to reddit content, as long as it's appropriately indicated that those are direct quotes and you link to the source.
        """# + "\n"

    public static let webRunSchema: JSONValue = webRunObjectSchema(properties: [
        "search_query": webRunArraySchema(
            "Query the internet search engine for a given list of queries.",
            items: webRunSearchQuerySchema
        ),
        "image_query": webRunArraySchema(
            "Query the image search engine for a given list of queries.",
            items: webRunSearchQuerySchema
        ),
        "open": webRunArraySchema(
            "Open pages by reference id or URL.",
            items: webRunObjectSchema(properties: [
                "ref_id": webRunStringSchema("Reference id or URL to open."),
                "lineno": webRunIntegerSchema("Line number to position the page at."),
            ], required: ["ref_id"])
        ),
        "click": webRunArraySchema(
            "Open links from previously opened pages.",
            items: webRunObjectSchema(properties: [
                "ref_id": webRunStringSchema("Reference id containing the numbered link."),
                "id": webRunIntegerSchema("Numbered link id to open."),
            ], required: ["ref_id", "id"])
        ),
        "find": webRunArraySchema(
            "Find text patterns in pages.",
            items: webRunObjectSchema(properties: [
                "ref_id": webRunStringSchema("Reference id or URL to search within."),
                "pattern": webRunStringSchema("Text pattern to find."),
            ], required: ["ref_id", "pattern"])
        ),
        "screenshot": webRunArraySchema(
            "Take screenshots of PDF pages.",
            items: webRunObjectSchema(properties: [
                "ref_id": webRunStringSchema("Reference id or URL to screenshot."),
                "pageno": webRunIntegerSchema("Zero-indexed PDF page number."),
            ], required: ["ref_id", "pageno"])
        ),
        "finance": webRunArraySchema(
            "Look up prices for the given stock symbols.",
            items: webRunObjectSchema(properties: [
                "ticker": webRunStringSchema("Ticker symbol to look up."),
                "type": webRunEnumSchema(
                    "Asset type to look up.",
                    values: ["equity", "fund", "crypto", "index"]
                ),
                "market": webRunStringSchema(
                    "ISO 3166-1 alpha-3 country code, \"OTC\", or \"\" for cryptocurrency."
                ),
            ], required: ["ticker", "type"])
        ),
        "weather": webRunArraySchema(
            "Look up weather forecasts.",
            items: webRunObjectSchema(properties: [
                "location": webRunStringSchema("Location in \"Country, Area, City\" format."),
                "start": webRunStringSchema("Start date in YYYY-MM-DD format. Defaults to today."),
                "duration": webRunIntegerSchema("Number of days to return. Defaults to 7."),
            ], required: ["location"])
        ),
        "sports": webRunArraySchema(
            "Look up sports schedules and standings.",
            items: webRunObjectSchema(properties: [
                "tool": webRunEnumSchema("Tool name for sports requests.", values: ["sports"]),
                "fn": webRunEnumSchema(
                    "Sports function to call.", values: ["schedule", "standings"]
                ),
                "league": webRunEnumSchema(
                    "League to look up.",
                    values: ["nba", "wnba", "nfl", "nhl", "mlb", "epl", "ncaamb", "ncaawb", "ipl"]
                ),
                "team": webRunStringSchema(
                    "Team to look up, using the common 3 or 4 letter alias used in broadcasts."
                ),
                "opponent": webRunStringSchema(
                    "Opponent to use with `team` when narrowing the lookup."
                ),
                "date_from": webRunStringSchema("Start date in YYYY-MM-DD format."),
                "date_to": webRunStringSchema("End date in YYYY-MM-DD format."),
                "num_games": webRunIntegerSchema("Number of games to return."),
                "locale": webRunStringSchema("Locale for the lookup."),
            ], required: ["fn", "league"])
        ),
        "time": webRunArraySchema(
            "Get time for the given UTC offsets.",
            items: webRunObjectSchema(properties: [
                "utc_offset": webRunStringSchema("UTC offset formatted like \"+03:00\"."),
            ], required: ["utc_offset"])
        ),
        "response_length": webRunEnumSchema(
            "Set the length of the response to be returned.",
            values: ["short", "medium", "long"]
        ),
    ])

    /// Separate from `webTools`: existing search/fetch/X toolsets remain unchanged.
    public static let webRunTools: [RegisteredToolSpec] = [
        RegisteredToolSpec(
            namespace: .grokBuild,
            id: "web__run",
            kind: .webSearch,
            description: webRunDescription,
            inputSchema: webRunSchema
        ),
    ]

    public static let webRunQualifiedId = "GrokBuild:web__run"

    public static var webRunToolKinds: [String: ProductToolKind] {
        Dictionary(uniqueKeysWithValues: webRunTools.map { ($0.qualifiedId, $0.kind) })
    }
}

private let webRunSearchQuerySchema = webRunObjectSchema(properties: [
    "q": webRunStringSchema("Search query."),
    "recency": webRunIntegerSchema("Whether to filter by recency, as a number of recent days."),
    "domains": webRunArraySchema(
        "Whether to filter by a specific list of domains.",
        items: .object(["type": .string("string")])
    ),
], required: ["q"])

private func webRunObjectSchema(
    properties: [String: JSONValue],
    required: [String] = []
) -> JSONValue {
    var schema: [String: JSONValue] = [
        "type": .string("object"),
        "properties": .object(properties),
    ]
    if !required.isEmpty {
        schema["required"] = .array(required.map(JSONValue.string))
    }
    return .object(schema)
}

private func webRunArraySchema(_ description: String, items: JSONValue) -> JSONValue {
    .object([
        "type": .string("array"),
        "description": .string(description),
        "items": items,
    ])
}

private func webRunStringSchema(_ description: String) -> JSONValue {
    .object(["type": .string("string"), "description": .string(description)])
}

private func webRunIntegerSchema(_ description: String) -> JSONValue {
    .object([
        "type": .string("integer"),
        "format": .string("uint64"),
        "minimum": .number(.uint64(0)),
        "description": .string(description),
    ])
}

private func webRunEnumSchema(_ description: String, values: [String]) -> JSONValue {
    .object([
        "type": .string("string"),
        "description": .string(description),
        "enum": .array(values.map(JSONValue.string)),
    ])
}
