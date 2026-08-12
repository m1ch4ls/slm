# slm Context

`slm` delegates focused text-processing tasks to a language model. This glossary distinguishes instructions for agents using `slm` from instructions governing the delegated model.

## Language

**Agent skill**:
Instructions that teach an external AI agent when and how to use `slm`.
_Avoid_: System prompt, model instructions

**Runtime system prompt**:
Instructions that govern the language model processing a particular `slm` request.
_Avoid_: Agent skill, usage guide

**Task instruction**:
The positional CLI text describing the transformation requested from `slm`.
_Avoid_: Prompt, input

**Source input**:
The raw byte sequence consumed from standard input for a processing attempt.
_Avoid_: Prompt, complete user message

**Model output**:
The text returned by the delegated language model for a successful processing attempt.
_Avoid_: Stdout, API response, diagnostics

**Delegated language model**:
The language model that processes an `slm` request and is expected to be cheaper and less capable than the agent's primary model.
_Avoid_: Local model, parameter-count claims

**Cheapest model**:
The delegated language model with the lowest estimated token cost for a workload composed of 90% uncached input tokens and 10% output tokens, using the applicable published prices.
_Avoid_: Lowest input price, cheapest provider

**Provider**:
The company operating an API through which a delegated language model is accessed.
_Avoid_: Compatibility protocol, endpoint

**Compatibility endpoint**:
An endpoint that accepts requests and returns responses shaped according to the OpenAI Chat Completions protocol, regardless of its provider.
_Avoid_: OpenAI provider

**Explicit configuration**:
A user-specified model and compatibility endpoint that bypass automatic selection.
_Avoid_: OpenAI configuration, custom provider

**Automatic selection**:
Choosing the cheapest model among providers for which a non-empty provider credential is configured, without testing remote model access.
_Avoid_: Provider autodetection, cheapest available

**Model manifest**:
The reviewed, committed dataset from which automatic selection obtains provider models, prices, and capacity limits.
_Avoid_: Pricing table, catalog

**Pricing table**:
The human-readable documentation rendering of the model manifest.
_Avoid_: Model manifest, source data

**Catalog snapshot**:
The models.dev dataset examined when regenerating the model manifest.
_Avoid_: Model manifest, runtime catalog

**Processing attempt**:
An `slm` invocation with a valid task instruction that has begun consuming input, regardless of whether processing succeeds.
_Avoid_: CLI run, request

## Relationships

- An **Agent skill** guides an agent that invokes `slm`
- A **Runtime system prompt** guides the model invoked by `slm`
- A **Delegated language model** follows the **Runtime system prompt**
- A **Processing attempt** has one **Task instruction** and one **Source input**, which may be empty
- A successful **Processing attempt** has one **Model output**
- A **Processing attempt** may fail before reaching the **Delegated language model**

## Example dialogue

> **Dev:** "Should concise output rules go in the **Agent skill**?"
> **Domain expert:** "No. If they govern the delegated model's response, they belong in the **Runtime system prompt**."
>
> **Dev:** "Do we retain a **Processing attempt** when its input is too large?"
> **Domain expert:** "Yes. It began consuming **Source input**, even though the **Delegated language model** was never called."

## Flagged ambiguities

- "Skill for AI" could mean either agent-facing usage instructions or model-facing request instructions; resolved as **Agent skill**.
- "Local small language model" does not describe every supported endpoint; resolved as a smaller **Delegated language model** without locality or parameter-count claims.
- "CLI run" included commands that perform no delegated work; resolved: storage covers **Processing attempts** only.
- "input" could mean the task text, stdin, or the formatted model message; resolved: **Task instruction** and byte-exact **Source input** are stored separately.
- "output" could mean model text, process stdout, stderr, or the raw API response; resolved: **Model output** is stored separately from a structured processing outcome.
