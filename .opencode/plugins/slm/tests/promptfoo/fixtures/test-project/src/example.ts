// Example TypeScript file for testing
// This file is used to test the SLM plugin's file reading capabilities

export interface Example {
  id: string;
  name: string;
  value: number;
}

export function processExample(data: Example): string {
  return `Processing ${data.name} with value ${data.value}`;
}

// Generate some test data
export const examples: Example[] = [
  { id: "1", name: "First", value: 100 },
  { id: "2", name: "Second", value: 200 },
  { id: "3", name: "Third", value: 300 },
];

// Simulate a larger file for testing
export function generateLines(count: number): string[] {
  return Array.from({ length: count }, (_, i) => 
    `Line ${i + 1}: This is example content for testing file operations with the slm plugin`
  );
}
