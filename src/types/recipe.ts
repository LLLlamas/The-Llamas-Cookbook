export type ID = string;

export interface Ingredient {
  id: ID;
  quantity?: string;
  unit?: string;
  name: string;
  order: number;
}

export interface Step {
  id: ID;
  order: number;
  text: string;
}

export interface Recipe {
  id: ID;
  title: string;
  description?: string;
  imageUri?: string;
  servings?: number;
  prepTimeMinutes?: number;
  cookTimeMinutes?: number;
  ovenTimeMinutes?: number;
  ingredients: Ingredient[];
  steps: Step[];
  notes: string;
  tags: string[];
  favorite: boolean;
  lastCookedAt?: string;
  cookCount: number;
  createdAt: string;
  updatedAt: string;
}

export type NewRecipeInput = Omit<Recipe, 'id' | 'createdAt' | 'updatedAt' | 'cookCount'>;
