# slm Context

`slm` delegates focused text-processing tasks to a language model. This glossary distinguishes instructions for agents using `slm` from instructions governing the delegated model.

## Language

**Agent skill**:
Instructions that teach an external AI agent when and how to use `slm`.
_Avoid_: System prompt, model instructions

**Runtime system prompt**:
Instructions that govern the language model processing a particular `slm` request.
_Avoid_: Agent skill, usage guide

**Delegated language model**:
The language model that processes an `slm` request and is expected to be cheaper and less capable than the agent's primary model.
_Avoid_: Local model, parameter-count claims

## Relationships

- An **Agent skill** guides an agent that invokes `slm`
- A **Runtime system prompt** guides the model invoked by `slm`
- A **Delegated language model** follows the **Runtime system prompt**

## Example dialogue

> **Dev:** "Should concise output rules go in the **Agent skill**?"
> **Domain expert:** "No. If they govern the delegated model's response, they belong in the **Runtime system prompt**."

## Flagged ambiguities

- "Skill for AI" could mean either agent-facing usage instructions or model-facing request instructions; resolved as **Agent skill**.
- "Local small language model" does not describe every supported endpoint; resolved as a smaller **Delegated language model** without locality or parameter-count claims.
