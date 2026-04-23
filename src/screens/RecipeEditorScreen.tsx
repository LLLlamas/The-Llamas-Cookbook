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
import { LlamaMascot } from '../components/LlamaMascot';
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
  const [ovenTime, setOvenTime] = useState(
    existing?.ovenTimeMinutes != null ? String(existing.ovenTimeMinutes) : '',
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
      ovenTimeMinutes: toOptionalNumber(ovenTime),
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
  const updateStep = (id: string, patch: Pick<Step, 'text'>) => {
    setSteps((prev) =>
      prev.map((s) => (s.id === id ? { ...s, ...patch } : s)),
    );
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
        <View style={styles.heroRow}>
          <LlamaMascot size={44} />
          <View style={styles.heroText}>
            <Text style={styles.heroTitle}>
              {editingId ? 'Edit recipe' : 'New recipe'}
            </Text>
            <Text style={styles.heroSubtitle}>
              Start with a name — the rest is up to you.
            </Text>
          </View>
        </View>

        <View style={styles.titleBlock}>
          <View style={styles.labelRow}>
            <Text style={styles.label}>Recipe name</Text>
            <Text style={styles.requiredBadge}>REQUIRED</Text>
          </View>
          <TextInput
            value={title}
            onChangeText={setTitle}
            placeholder="e.g. Grandma's Sunday pasta"
            placeholderTextColor={colors.textSecondary}
            style={styles.titleInput}
          />
        </View>

        <TextInput
          value={description}
          onChangeText={setDescription}
          placeholder="Short description (optional)"
          placeholderTextColor={colors.textSecondary}
          style={styles.descInput}
          multiline
        />

        <Text style={styles.sectionHeading}>Ingredients</Text>
        <Text style={styles.sectionHint}>
          Enter quantity, unit, and ingredient separately. Hit return after each.
        </Text>
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
        <Text style={styles.sectionHint}>
          One step per line. They'll be numbered and you'll check them off while cooking.
        </Text>
        <StepQuickAdd onAdd={addStep} nextNumber={steps.length + 1} />
        {steps.length > 0 ? (
          <View style={styles.list}>
            {steps.map((step, idx) => (
              <StepRow
                key={step.id}
                step={step}
                index={idx}
                onDelete={() => removeStep(step.id)}
                onUpdate={(patch) => updateStep(step.id, patch)}
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

        <View style={styles.optionalBlock}>
          <Text style={styles.optionalHeading}>Optional details</Text>
          <Text style={styles.sectionHint}>
            Set servings so you can scale ingredients up or down while cooking.
            Set Oven (min) and the timer will auto-suggest on your oven step.
          </Text>
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
            <View style={styles.metaField}>
              <Text style={styles.metaLabel}>Oven (min)</Text>
              <TextInput
                value={ovenTime}
                onChangeText={setOvenTime}
                placeholder="25"
                placeholderTextColor={colors.textSecondary}
                style={styles.metaInput}
                keyboardType="number-pad"
              />
            </View>
          </View>
        </View>
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
  heroRow: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: spacing.md,
    marginBottom: spacing.xs,
  },
  heroText: {
    flex: 1,
  },
  heroTitle: {
    fontFamily: fontFamilies.displayBold,
    fontSize: 20,
    lineHeight: 26,
    color: colors.textPrimary,
  },
  heroSubtitle: {
    ...textStyles.caption,
    color: colors.textSecondary,
  },
  titleBlock: {
    gap: spacing.xs,
  },
  labelRow: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: spacing.sm,
  },
  label: {
    fontFamily: fontFamilies.bodySemibold,
    fontSize: 13,
    lineHeight: 16,
    color: colors.textPrimary,
    textTransform: 'uppercase',
    letterSpacing: 0.8,
  },
  requiredBadge: {
    fontFamily: fontFamilies.bodySemibold,
    fontSize: 10,
    lineHeight: 14,
    color: colors.accent,
    letterSpacing: 0.8,
  },
  titleInput: {
    ...textStyles.recipeTitle,
    color: colors.textPrimary,
    backgroundColor: colors.surface,
    borderRadius: radius.md,
    borderWidth: 2,
    borderColor: colors.accent,
    paddingHorizontal: spacing.md,
    paddingVertical: spacing.md,
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
  sectionHeading: {
    ...textStyles.sectionHeading,
    color: colors.textPrimary,
    marginTop: spacing.md,
  },
  sectionHint: {
    ...textStyles.caption,
    color: colors.textSecondary,
    marginBottom: spacing.xs,
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
  optionalBlock: {
    marginTop: spacing.xl,
    padding: spacing.md,
    backgroundColor: colors.surface,
    borderRadius: radius.md,
    borderWidth: 1,
    borderColor: colors.divider,
    gap: spacing.xs,
  },
  optionalHeading: {
    fontFamily: fontFamilies.display,
    fontSize: 16,
    lineHeight: 22,
    color: colors.textPrimary,
  },
  metaRow: {
    flexDirection: 'row',
    flexWrap: 'wrap',
    gap: spacing.sm,
    marginTop: spacing.xs,
  },
  metaField: {
    flexBasis: '47%',
    flexGrow: 1,
    gap: spacing.xs,
  },
  metaLabel: {
    ...textStyles.caption,
    color: colors.textSecondary,
  },
  metaInput: {
    ...textStyles.body,
    color: colors.textPrimary,
    backgroundColor: colors.background,
    borderRadius: radius.md,
    borderWidth: 1,
    borderColor: colors.divider,
    paddingHorizontal: spacing.md,
    paddingVertical: spacing.sm,
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
