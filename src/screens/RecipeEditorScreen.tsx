import { useEffect, useLayoutEffect, useState } from 'react';
import {
  Alert,
  KeyboardAvoidingView,
  Platform,
  Pressable,
  ScrollView,
  StyleSheet,
  Text,
  TextInput,
  View,
} from 'react-native';
import { useSafeAreaInsets } from 'react-native-safe-area-context';
import type { NativeStackScreenProps } from '@react-navigation/native-stack';
import { IngredientQuickAdd } from '../components/IngredientQuickAdd';
import { IngredientRow } from '../components/IngredientRow';
import { StepQuickAdd } from '../components/StepQuickAdd';
import { StepRow } from '../components/StepRow';
import { TagInput } from '../components/TagInput';
import { colors } from '../theme/colors';
import { radius, spacing } from '../theme/spacing';
import { fontFamilies, textStyles } from '../theme/typography';
import { useRecipesStore } from '../store/recipesStore';
import type { Ingredient, Recipe, Step } from '../types/recipe';
import type { RootStackParamList } from '../navigation/RootStack';

type Props = NativeStackScreenProps<RootStackParamList, 'RecipeEditor'>;

const toOptionalNumber = (s: string): number | undefined => {
  if (!s.trim()) return undefined;
  const n = Number(s);
  return Number.isFinite(n) && n >= 0 ? n : undefined;
};

export function RecipeEditorScreen({ route, navigation }: Props) {
  const editingId = route.params?.id;
  const existing = useRecipesStore((s) =>
    editingId ? s.recipes[editingId] : undefined,
  );
  const addRecipe = useRecipesStore((s) => s.addRecipe);
  const updateRecipe = useRecipesStore((s) => s.updateRecipe);
  const insets = useSafeAreaInsets();

  const [title, setTitle] = useState(existing?.title ?? '');
  const [description, setDescription] = useState(existing?.description ?? '');
  const [servings, setServings] = useState(
    existing?.servings != null ? String(existing.servings) : '',
  );
  const [prepTime, setPrepTime] = useState(
    existing?.prepTimeMinutes != null ? String(existing.prepTimeMinutes) : '',
  );
  const [cookTime, setCookTime] = useState(
    existing?.cookTimeMinutes != null ? String(existing.cookTimeMinutes) : '',
  );
  const [ingredients, setIngredients] = useState<Ingredient[]>(
    existing?.ingredients ?? [],
  );
  const [steps, setSteps] = useState<Step[]>(existing?.steps ?? []);
  const [tags, setTags] = useState<string[]>(existing?.tags ?? []);
  const [notes, setNotes] = useState(existing?.notes ?? '');

  useLayoutEffect(() => {
    navigation.setOptions({ title: editingId ? 'Edit Recipe' : 'New Recipe' });
  }, [navigation, editingId]);

  useEffect(() => {
    if (editingId && !existing) {
      navigation.goBack();
    }
  }, [editingId, existing, navigation]);

  const canSave = title.trim().length > 0;

  const handleSave = () => {
    if (!canSave) return;
    const payload = {
      title: title.trim(),
      description: description.trim() || undefined,
      servings: toOptionalNumber(servings),
      prepTimeMinutes: toOptionalNumber(prepTime),
      cookTimeMinutes: toOptionalNumber(cookTime),
      ingredients: ingredients.map((i, idx) => ({ ...i, order: idx })),
      steps: steps.map((s, idx) => ({ ...s, order: idx })),
      tags,
      notes,
      favorite: existing?.favorite ?? false,
      imageUri: existing?.imageUri,
      lastCookedAt: existing?.lastCookedAt,
    } satisfies Omit<Recipe, 'id' | 'createdAt' | 'updatedAt' | 'cookCount'>;

    if (editingId) {
      updateRecipe(editingId, payload);
    } else {
      addRecipe(payload);
    }
    navigation.goBack();
  };

  const handleCancel = () => {
    const hasContent =
      title.trim().length > 0 ||
      ingredients.length > 0 ||
      steps.length > 0 ||
      description.trim().length > 0 ||
      notes.trim().length > 0;
    if (hasContent) {
      Alert.alert('Discard changes?', 'Your edits will be lost.', [
        { text: 'Keep editing', style: 'cancel' },
        {
          text: 'Discard',
          style: 'destructive',
          onPress: () => navigation.goBack(),
        },
      ]);
    } else {
      navigation.goBack();
    }
  };

  const addIngredient = (draft: Omit<Ingredient, 'order'>) => {
    setIngredients((prev) => [...prev, { ...draft, order: prev.length }]);
  };
  const removeIngredient = (id: string) => {
    setIngredients((prev) => prev.filter((i) => i.id !== id));
  };
  const updateIngredient = (
    id: string,
    patch: Pick<Ingredient, 'quantity' | 'unit' | 'name'>,
  ) => {
    setIngredients((prev) =>
      prev.map((i) => (i.id === id ? { ...i, ...patch } : i)),
    );
  };

  const addStep = (draft: Omit<Step, 'order'>) => {
    setSteps((prev) => [...prev, { ...draft, order: prev.length }]);
  };
  const removeStep = (id: string) => {
    setSteps((prev) => prev.filter((s) => s.id !== id));
  };

  return (
    <KeyboardAvoidingView
      style={styles.container}
      behavior={Platform.OS === 'ios' ? 'padding' : undefined}
    >
      <ScrollView
        style={styles.scroll}
        contentContainerStyle={[
          styles.content,
          { paddingBottom: insets.bottom + 120 },
        ]}
        keyboardShouldPersistTaps="handled"
      >
        <TextInput
          value={title}
          onChangeText={setTitle}
          placeholder="Recipe title"
          placeholderTextColor={colors.textSecondary}
          style={styles.titleInput}
        />

        <TextInput
          value={description}
          onChangeText={setDescription}
          placeholder="Short description (optional)"
          placeholderTextColor={colors.textSecondary}
          style={styles.descInput}
          multiline
        />

        <View style={styles.metaRow}>
          <View style={styles.metaField}>
            <Text style={styles.metaLabel}>Servings</Text>
            <TextInput
              value={servings}
              onChangeText={setServings}
              placeholder="4"
              placeholderTextColor={colors.textSecondary}
              style={styles.metaInput}
              keyboardType="number-pad"
            />
          </View>
          <View style={styles.metaField}>
            <Text style={styles.metaLabel}>Prep (min)</Text>
            <TextInput
              value={prepTime}
              onChangeText={setPrepTime}
              placeholder="15"
              placeholderTextColor={colors.textSecondary}
              style={styles.metaInput}
              keyboardType="number-pad"
            />
          </View>
          <View style={styles.metaField}>
            <Text style={styles.metaLabel}>Cook (min)</Text>
            <TextInput
              value={cookTime}
              onChangeText={setCookTime}
              placeholder="30"
              placeholderTextColor={colors.textSecondary}
              style={styles.metaInput}
              keyboardType="number-pad"
            />
          </View>
        </View>

        <Text style={styles.sectionHeading}>Ingredients</Text>
        <IngredientQuickAdd onAdd={addIngredient} />
        {ingredients.length > 0 ? (
          <View style={styles.list}>
            {ingredients.map((ingredient) => (
              <IngredientRow
                key={ingredient.id}
                ingredient={ingredient}
                onDelete={() => removeIngredient(ingredient.id)}
                onUpdate={(patch) => updateIngredient(ingredient.id, patch)}
              />
            ))}
          </View>
        ) : null}

        <Text style={styles.sectionHeading}>Steps</Text>
        <StepQuickAdd onAdd={addStep} nextNumber={steps.length + 1} />
        {steps.length > 0 ? (
          <View style={styles.list}>
            {steps.map((step, idx) => (
              <StepRow
                key={step.id}
                step={step}
                index={idx}
                onDelete={() => removeStep(step.id)}
              />
            ))}
          </View>
        ) : null}

        <Text style={styles.sectionHeading}>Tags</Text>
        <TagInput tags={tags} onChange={setTags} />

        <Text style={styles.sectionHeading}>Notes</Text>
        <TextInput
          value={notes}
          onChangeText={setNotes}
          placeholder="Optional notes — e.g. use less salt next time"
          placeholderTextColor={colors.textSecondary}
          style={styles.notesInput}
          multiline
        />
      </ScrollView>

      <View style={[styles.actionBar, { paddingBottom: insets.bottom + spacing.md }]}>
        <Pressable style={[styles.btn, styles.btnSecondary]} onPress={handleCancel}>
          <Text style={styles.btnSecondaryText}>Cancel</Text>
        </Pressable>
        <Pressable
          style={[styles.btn, styles.btnPrimary, !canSave && styles.btnDisabled]}
          onPress={handleSave}
          disabled={!canSave}
        >
          <Text style={styles.btnPrimaryText}>Save</Text>
        </Pressable>
      </View>
    </KeyboardAvoidingView>
  );
}

const styles = StyleSheet.create({
  container: {
    flex: 1,
    backgroundColor: colors.background,
  },
  scroll: {
    flex: 1,
  },
  content: {
    padding: spacing.lg,
    gap: spacing.md,
  },
  titleInput: {
    ...textStyles.recipeTitle,
    color: colors.textPrimary,
    paddingVertical: spacing.sm,
  },
  descInput: {
    ...textStyles.body,
    color: colors.textPrimary,
    backgroundColor: colors.surface,
    borderRadius: radius.md,
    borderWidth: 1,
    borderColor: colors.divider,
    padding: spacing.md,
    minHeight: 56,
    textAlignVertical: 'top',
  },
  metaRow: {
    flexDirection: 'row',
    gap: spacing.sm,
  },
  metaField: {
    flex: 1,
    gap: spacing.xs,
  },
  metaLabel: {
    ...textStyles.caption,
    color: colors.textSecondary,
  },
  metaInput: {
    ...textStyles.body,
    color: colors.textPrimary,
    backgroundColor: colors.surface,
    borderRadius: radius.md,
    borderWidth: 1,
    borderColor: colors.divider,
    paddingHorizontal: spacing.md,
    paddingVertical: spacing.sm,
  },
  sectionHeading: {
    ...textStyles.sectionHeading,
    color: colors.textPrimary,
    marginTop: spacing.md,
  },
  list: {
    gap: 2,
  },
  notesInput: {
    ...textStyles.body,
    color: colors.textPrimary,
    backgroundColor: colors.surface,
    borderRadius: radius.md,
    borderWidth: 1,
    borderColor: colors.divider,
    padding: spacing.md,
    minHeight: 96,
    textAlignVertical: 'top',
  },
  actionBar: {
    position: 'absolute',
    left: 0,
    right: 0,
    bottom: 0,
    flexDirection: 'row',
    gap: spacing.md,
    padding: spacing.lg,
    paddingTop: spacing.md,
    backgroundColor: colors.background,
    borderTopWidth: 1,
    borderTopColor: colors.divider,
  },
  btn: {
    flex: 1,
    alignItems: 'center',
    justifyContent: 'center',
    paddingVertical: spacing.md,
    borderRadius: radius.md,
  },
  btnPrimary: {
    backgroundColor: colors.accent,
  },
  btnPrimaryText: {
    fontFamily: fontFamilies.bodySemibold,
    fontSize: 16,
    color: '#FFFDF8',
  },
  btnSecondary: {
    backgroundColor: colors.surface,
    borderWidth: 1,
    borderColor: colors.divider,
  },
  btnSecondaryText: {
    fontFamily: fontFamilies.bodyMedium,
    fontSize: 16,
    color: colors.textPrimary,
  },
  btnDisabled: {
    opacity: 0.4,
  },
});
