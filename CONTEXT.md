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
