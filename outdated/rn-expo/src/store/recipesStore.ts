import { create } from 'zustand';
import { persist } from 'zustand/middleware';
import type { ID, NewRecipeInput, Recipe } from '../types/recipe';
import { newId } from '../lib/ids';
import { RECIPES_STORAGE_KEY, zustandAsyncStorage } from './persistConfig';

interface RecipesState {
  recipes: Record<ID, Recipe>;
  hydrated: boolean;

  _setHydrated: (v: boolean) => void;

  list: () => Recipe[];
  getById: (id: ID) => Recipe | undefined;

  addRecipe: (input: NewRecipeInput) => Recipe;
  updateRecipe: (id: ID, patch: Partial<Recipe>) => void;
  deleteRecipe: (id: ID) => void;
  markCooked: (id: ID) => void;
  toggleFavorite: (id: ID) => void;
}

const nowIso = () => new Date().toISOString();

export const useRecipesStore = create<RecipesState>()(
  persist(
    (set, get) => ({
      recipes: {},
      hydrated: false,

      _setHydrated: (v) => set({ hydrated: v }),

      list: () =>
        Object.values(get().recipes).sort((a, b) =>
          b.createdAt.localeCompare(a.createdAt),
        ),

      getById: (id) => get().recipes[id],

      addRecipe: (input) => {
        const now = nowIso();
        const recipe: Recipe = {
          ...input,
          id: newId(),
          cookCount: 0,
          createdAt: now,
          updatedAt: now,
        };
        set((s) => ({ recipes: { ...s.recipes, [recipe.id]: recipe } }));
        return recipe;
      },

      updateRecipe: (id, patch) => {
        set((s) => {
          const current = s.recipes[id];
          if (!current) return s;
          return {
            recipes: {
              ...s.recipes,
              [id]: { ...current, ...patch, id, updatedAt: nowIso() },
            },
          };
        });
      },

      deleteRecipe: (id) => {
        set((s) => {
          if (!s.recipes[id]) return s;
          const next = { ...s.recipes };
          delete next[id];
          return { recipes: next };
        });
      },

      markCooked: (id) => {
        set((s) => {
          const current = s.recipes[id];
          if (!current) return s;
          const now = nowIso();
          return {
            recipes: {
              ...s.recipes,
              [id]: {
                ...current,
                lastCookedAt: now,
                cookCount: current.cookCount + 1,
                updatedAt: now,
              },
            },
          };
        });
      },

      toggleFavorite: (id) => {
        set((s) => {
          const current = s.recipes[id];
          if (!current) return s;
          return {
            recipes: {
              ...s.recipes,
              [id]: {
                ...current,
                favorite: !current.favorite,
                updatedAt: nowIso(),
              },
            },
          };
        });
      },
    }),
    {
      name: RECIPES_STORAGE_KEY,
      storage: zustandAsyncStorage,
      partialize: (s) => ({ recipes: s.recipes }),
      onRehydrateStorage: () => (state) => {
        state?._setHydrated(true);
      },
    },
  ),
);
