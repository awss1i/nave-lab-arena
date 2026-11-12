
A Better Way to Parse Documents?
====================

Whether we parse JSON or XML, or any other serialized format, there are relatively few common strategies:

- The most established approach is the construction of document-object-model (DOM).
- Another established approach is a event-based approach (like SAX, SAJ).
- Another popular approach is the schema-based deserialization model.

We propose an approach that is as easy to use and often as flexible as the DOM approach, yet as fast and
efficient as the schema-based or event-based approaches. We call this new approach "On-Demand". The
simdjson On-Demand API offers a familiar, friendly DOM API and
provides the performance of just-in-time parsing on top of the simdjson superior performance.

To achieve ease of use, we mimicked the *form* of a traditional DOM API: you can iterate over
arrays, look up fields in objects, and extract native values like `double`, `uint64_t`, `string` and `bool`.

To achieve performance, we introduced some key limitations that make the DOM API *streaming*:
array/object iteration cannot be restarted, and string/number values can only be parsed once. If
these limitations are acceptable to you, the On-Demand API could help you write maintainable
applications with a computation efficiency that is difficult to surpass.

A code example illustrates our API from a programmer's point of view:

```cpp
ondemand::parser parser;
auto doc = parser.iterate(json);
for (auto tweet : doc["statuses"]) {
  std::string_view text        = tweet["text"];
  std::string_view screen_name = tweet["user"]["screen_name"];
  uint64_t         retweets    = tweet["retweet_count"];
  uint64_t         favorites   = tweet["favorite_count"];
  cout << screen_name << " (" << retweets << " retweets / " << favorites << " favorites): " << text << endl;
}
```

Such code would be apply to a JSON document such as the following JSON mimicking a sample result from the Twitter API:

```json
{
	"statuses": [{
			"text": "@aym0566x \n\n名前:前田あゆみ\n第一印象:なんか怖っ！\n今の印象:とりあえずキモい。噛み合わない\n好きなところ:ぶすでキモいとこ😋✨✨\n思い出:んーーー、ありすぎ😊❤️\nLINE交換できる？:あぁ……ごめん✋\nトプ画をみて:照れますがな😘✨\n一言:お前は一生もんのダチ💖",
			"user": {
				"name": "AYUMI",
				"screen_name": "ayuu0123",
				"followers_count": 262,
				"friends_count": 252
			},
			"retweet_count": 0,
			"favorite_count": 0
		},
		{
			"text": "RT @KATANA77: えっそれは・・・（一同） http://t.co/PkCJAcSuYK",
			"user": {
				"name": "RT&ファボ魔のむっつんさっm",
				"screen_name": "yuttari1998",
				"followers_count": 95,
				"friends_count": 158
			},
			"retweet_count": 82,
			"favorite_count": 42
		}
  ],
  "search_metadata": {
    "count": 100,
  }
}
```

This streaming approach means that unused fields and values are not parsed or
converted, thus saving space and time. In our example, the `"name"`, `"followers_count"`,
and `"friends_count"` keys and matching values are skipped.

Further, the On-Demand API does not parse a value *at all* until you try to convert it (e.g., to `double`,
`int`, `string`, or `bool`). In our example, when accessing the key-value pair `"retweet_count": 82`, the parser
may not convert the pair of characters `82` to the binary integer 82. Because the programmer specifies the data
type, we avoid branch mispredictions related to data type determination and improve the performance.


We expect users of an On-Demand API to work in terms of a JSON dialect, which is a set of expectations and
specifications that come in addition to the [JSON specification](https://www.rfc-editor.org/rfc/rfc8259.txt).
The On-Demand approach is designed around several principles:

* **Streaming (\*):** It avoids preparsing values, keeping the memory usage and the latency down.
* **Forward-Only:** To prevent reiteration of the same values and to keep the number of variables down (literally), only a single index is maintained and everything uses it (even if you have nested for loops). This means when you are going through an array of arrays, for example, that the inner array loop will advance the index to the next comma, and the array can just pick it up and look at it.
* **Natural Iteration:** A JSON array or object can be iterated with a normal C++ for loop. Nested arrays and objects are supported by nested for loops.
* **Use-Specific Parsing:** Parsing is always specific to the type required by the programmer. For example, if the programmer asks for an unsigned integer, we just start parsing digits. If there were no digits, we toss an error. There are even different parsers for `double`, `uint64_t` and `int64_t` values. This use-specific parsing avoids the branchiness of a generic "type switch," and makes the code more inlineable and compact.
* **Validate What You Use:** On-Demand deliberately validates the values you use and the structure leading to it, but nothing else. The goal is a guarantee that the value you asked for is the correct one and is not malformed: there must be no confusion over whether you got the right value.


To understand why On-Demand is different, it is helpful to review the major
approaches to parsing and parser APIs in use today.

### DOM Parsers

Many of the most usable, popular JSON APIs (including simdjson) deserialize into a **DOM**: an intermediate tree of
objects, arrays and values. In this model, we convert the input data all at once into a tree-like structure (the DOM).
The DOM is then accessed by the programmer like any other in-memory data structure. The resulting API let
you refer to each array or object separately, using familiar techniques like iteration (`for (auto value : array)`)
or indexing (`object["key"]`). In some cases, the values are even deserialized directly into familiar C++ constructs like vectors and
maps.

The DOM approach is conceptually simple and "programmer friendly". Using the
DOM tree is often easy enough that many users process the DOM as-is instead of creating
their own custom data structures.

The DOM approach was the only way to parse JSON documents up to version 0.6 of the simdjson library.
Our DOM API looks similar to our On-Demand example, except
it calls `parse` instead of `iterate`:

```cpp
dom::parser parser;
auto doc = parser.parse(json);
for (auto tweet : doc["statuses"]) {
  std::string_view text        = tweet["text"];
  std::string_view screen_name = tweet["user"]["screen_name"];
  uint64_t         retweets    = tweet["retweet_count"];
  cout << screen_name << " (" << retweets << " retweets): " << text << endl;
}
```

Pros of the DOM approach:
* Straightforward, programmer-friendly interface (arrays and objects).
* Safe: all of the input data has been validated before it is accessed.
* All of the JSON document is available at once to the programmer.

Cons of the DOM approach:
* The memory usage scales linearly with the size of the input document.
* Parses and stores everything, using memory and CPU cycles even on unused values.
* Performance drain from [type blindness](#type-blindness).


What the simdjson library demonstrates is that a DOM API may be quite fast indeed: we can parse files at speeds
of several gigabytes per second. However, in some instances, it may be possible to achieve even higher speeds.

### Event-Based Parsers (SAX, SAJ, etc.)


The event-based model (originally from the "Streaming API for XML") uses streaming to eliminate the cost of
parsing and storing the entire JSON. In the event-based model, a core JSON engine parses the JSON document
piece by piece, but instead of stuffing values in a DOM tree, it passes each value to a callback function,
letting the user decide for themselves how to handle it. In such a model, the programmer may need to provide functions
for all possible events (a number, a string, a new object, a new array, the array ends, the object ends, and so on).
This allows programmers to work with much larger files without running out of memory.

The drawback is complexity: event-based APIs generally have you define a single callback for each type
(e.g. `string_field(std::string_view key, std::string_view value)`). Because of this, the programmer suffers
from context blindness: when they find a string they have to check where it is before they know what to
do with it. Is this string the text of the tweet, the screen name, or something else? Are we even in
a tweet right now, or is this from some other place in the document
entirely? Though an event-based approach may allow superior performance, it is demanding of the programmer
who must efficiently keep track of its current state within the JSON input.

The following is event-based example of the Twitter problem we have reviewed in the DOM and On-Demand
examples. To make it short enough to use as an example at all, it has heavily redacted: it only solves
a part of the problem (does not get user.screen_name), it has bugs (it does not handle sub-objects
in a tweet at all), and it uses a theoretical, simple event-based API that minimizes ceremony.

```cpp
struct twitter_callbacks {
  bool in_statuses;
  bool in_tweet;
  std::string_view text;
  uint64_t         retweets;
  uint64_t         favorites;
  void start_object_field(std::string_view key) {
    if (key == "statuses") { in_statuses = true; }
  }
  void start_object() {
    if (in_statuses) { in_tweet = true; }
  }
  void string_field(std::string_view key, std::string_view value) {
    if (in_tweet && key == "text") { text = value; }
  }
  void number_field(std::string_view key, uint64_t value) {
    if (in_tweet) {
      if (key == "retweet_count") { retweets = value; }
      if (key == "favorite_count") { favorites = value; }
    }
  }
  void end_object() {
    if (in_tweet) {
      cout << "[redacted] (" << retweets << " retweets / " << favorites << " favorites): " << text << endl;
      in_tweet = false;
    } else if (in_statuses) {
      in_statuses = false;
    }
  }
};
sax::parser parser;
parser.parse(twitter_callbacks());
```

This is a large amount of code, requiring mental gymnastics even to read. An actual implementation is  harder to write
and to maintain.


Pros of the event-based approach:
* Speed and space benefits from low, predictable memory usage.
* Parsing can be done more lazily: the API can delegate work to the programmer for better performance.
* It is highly flexible: given enough effort, most tasks can be accomplished efficiently.

Cons of the event-based approach:
* Performance drain from context blindness (e.g., switch statements for "where am I in the document")
* Difficult to use (high code complexity, high maintenance, difficult to debug)
* Lacks the safety of DOM: malformed documents could be ingested.

Though an event-based approach might have its niche uses, we believe that it is rarely ideally suited. We suspect that it is mostly used when performance and memory is a concern, and no other option (except DOM) is readily available.

### Schema-Based Parser Generators


In a schema-based model, the programmer provides a description of a data structure, and the parser constructs the data structure in question during parsing. These parsers take a schema--a description of
your JSON, with field names, types, everything--and generate classes/structs in your language of
choice, as well as a parser to deserialize the JSON into those structs. Some such parsers let you
define your own data structures (`struct`) and they let a preprocessor inspects it and generates a custom JSON parser for it.
Though not all of these schema-based parser generators generate a parser or even optimize for
streaming, but they are *able* to in principle. Unlike the DOM and the event-based models, a schema-based approach assumes
 that the structure of the document is known at compile-time.


Pros of the schema-based approach:
* Ease of Use is on par with DOM
* Parsers that generate iterators and lazy values in structs can keep memory pressure down to event-based levels.
* Type Blindness can be entirely solved with specific parsers for each type, saving many branches.
* Context Blindness can be solved, especially if object fields are required and in order, saving even more branches.
* Can be made a safe as DOM: the input can be entirely validated prior to ingestion.

Cons of the schema-based approach:
* It is less flexible than the DOM or event-based approaches, sometimes limited to a deserialization-to-objects scenario.
* The structure of the data must be fully known at compile-time.


### Type Blindness and Branch Misprediction

The DOM and event-based parsing model suffer from **type
blindness**: even when the programmer knows exactly what fields and what types are in the JSON document,
the parser does not. This means it has to look at each value blind with a big "switch"
statement, asking "is this a number? A string? A boolean? An array? An object?"

In modern processors, this kind of switch statement can make your program run slower
than it needs to because of the high cost of branch misprediction. Indeed, modern processor
cores rely on speculative execution for speed. They "read ahead" in your program, predicting
which instructions to run as soon as the data is available. A single-threaded program can
execute 2, 3 or even more instructions per cycle--largely because of speculative execution.

Unfortunately, when the processor mispredicts the instructions, typically due to a mispredicted
branch, all of the work done from the misprediction has be discarded and started anew. The
processor may have been executing 3 or 4 instructions per cycle, and consuming the corresponding
power, but all of the work may have been wasteful.

Type blindness means that the processor has to guess, for every JSON value, whether it will be an array,
an object, number, string or boolean since these correspond to distinct code paths.
Though some JSON files have predictable content, we find in practice that many JSON files
stress the branch prediction. Though branch predictors improve with each new generation of processors,
the cost of branch mispredictions also tends to increase as pipelines expand, and the processors become
able to schedule longer streams of instructions.

On-Demand parsing is tailor-made to solve this problem at the source, parsing values only after the
user declares their type by asking for a `double`, an `int`, a `string`, etc. It attempts to do so while
preserving most of the flexibility of DOM parsing.

Algorithm
---------

To help visualize the algorithm, we'll walk through the example C++ given at the top, for this JSON:

```json
{
  "statuses": [
    { "id": 1, "text": "first!", "user": { "screen_name": "lemire", "name": "Daniel" }, "retweet_count": 40 },
    { "id": 2, "text": "second!", "user": { "screen_name": "jkeiser2", "name": "John" }, "retweet_count": 3 }
  ],
  "search_metadata": { "count": 2 }
}
```

### Starting the iteration

1. First, we declare a parser object that keeps internal buffers necessary for parsing. This can be
   reused to parse multiple JSON files, so you do not pay the high cost of allocating memory every
   time (and so it can stay in cache!).

   This declaration does not allocate any memory; that will happen in the next step.

   ```cpp
   ondemand::parser parser;
   ```

2. We then start iterating the JSON document by allocating internal parser buffers, preprocessing
   the JSON, and initializing the iterator.

   ```cpp
   auto doc = parser.iterate(json);
   ```

   Since this is the first time this parser has been used, `iterate()` first allocates internal
   parser buffers if this is the first time through. When reusing an existing parser, allocation
   only happens if the new document is bigger than internal buffers can handle. The On-Demand
   API only ever allocates memory in the `iterate()` function call.

   The simdjson library then preprocesses the JSON text at high speed, finding all tokens (i.e. the starting
   position of any JSON value, as well as any important operators like `,`, `:`, `]` or `}`).

   Finally, a `document` iterator is created, initialized at the position of the first value in the
   `json` text input. The document iterator is bumped forward by array / object iterators and
   object[] lookup, and must be kept around until iteration is complete.

   This operation can fail as this stage if the document in invalid! The result type is `simdjson_result<document>`.
   The simdjson library uses `simdjson_result` when a value needs to be returned by a function that can fail given improper inputs.
   The `simdjson_result` value contain an `error_code` and a `document`, and it was designed to allow you to use either error code
   checking or C++ exceptions via a direct cast `document(parser.iterate(json))` you can use `get()`
   to check the error and cast to a value, or cast directly to a value. However, the simdjson library
   rely on error chaining, so it is possible to delay error checks: we shall shortly explain error
   chaining more fully.

   > NOTE: You should always have such a `document` instance (here `doc`) and it should remain in scope for the duration
   > of your parsing function. E.g., you should not use the returned document as a temporary (e.g., `auto x = parser.iterate(json).get_object();`)
   > followed by other operations as the destruction of the `document` instance makes all of the derived instances
   > ill-defined.

   At this point, the iterator is at the start of the JSON:

   ```json
   {
   ^ (depth 1)

     "statuses": [
       { "id": 1, "text": "first!", "user": { "screen_name": "lemire", "name": "Daniel" }, "retweet_count": 40 },
       { "id": 2, "text": "second!", "user": { "screen_name": "jkeiser2", "name": "John" }, "retweet_count": 3 }
     ],
     "search_metadata": { "count": 2 }
   }
   ```

3. We iterate over the "statuses" field using a typical C++ iterator, reading past the initial
   `{ "statuses": [ {`.

   ```cpp
   for (ondemand::object tweet : doc["statuses"]) {
   ```

   This shorthand does a lot, and it is helpful to see what it expands to.
   Comments in front of each one explain what's going on:

   ```cpp
   // Validate that the top-level value is an object: check for {. Increase depth to 2 (root > field).
   ondemand::object top = doc.get_object();

   // Find the field statuses by:
   // 1. Check whether the object is empty (check for }). (We do not really need to do this unless
   //    the key lookup fails!)
   // 2. Check if we're at the field by looking for the string "statuses" using byte-by-byte comparison.
   // 3. Validate that there is a `:` after it.
   auto tweets_field = top["statuses"];

   // - Validate that the field value is an array: check for [
   // - If the array is empty (if there is a ] next), decrease depth back to 0.
   // - If not, increase depth to 3 (root > statuses > tweet).
   ondemand::array tweets = tweets_field.get_array();
   // These three method calls do nothing substantial (the real checking happens in get_array() and ++)
   // != checks whether the array is finished (if we found a ] and decreased depth back to 0).
   ondemand::array_iterator tweets_iter = tweets.begin();
   while (tweets_iter != tweets.end()) {
     auto tweet_value = *tweets_iter;

     // - Validate that the array element is an object: check for {
     // - If the object is empty (if there is a } next), decrease depth back to 1.
     // - If not, increase depth to 4 (root > statuses > tweet > field).
     ondemand::object tweet = tweet_value.get_object();
     ...
   }
   ```

   > NOTE: What is not explained in this code expansion is *error chaining*.
   > Generally, you can use `document` methods on a `simdjson_result<...>` value; any errors will
   > just be passed down the chain. Many method calls
   > can be chained in this manner. So `for (object tweet : doc["statuses"])`, which is the 