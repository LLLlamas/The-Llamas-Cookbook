import type { ID, Recipe } from '../types/recipe';

export interface RecipesRepo {
  getAll(): Promise<Recipe[]>;
  getById(id: ID): Promise<Recipe | null>;
  upsert(recipe: Recipe): Promise<void>;
  delete(id: ID): Promise<void>;
}
