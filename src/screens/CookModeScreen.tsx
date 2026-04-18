import { useEffect, useMemo, useState } from 'react';
import {
  Alert,
  Pressable,
  ScrollView,
  StyleSheet,
  Text,
  View,
} from 'react-native';
import { useSafeAreaInsets } from 'react-native-safe-area-context';
import { useKeepAwake } from 'expo-keep-awake';
import { Minus, Plus, X } from 'lucide-react-native';
import type { NativeStackScreenProps } from '@react-navigation/native-stack';
import { colors } from '../theme/colors';
import { radius, spacing } from '../theme/spacing';
import { fontFamilies, textStyles } from '../theme/typography';
import { scaleQuantity } from '../lib/scaleQuantity';
import { useRecipesStore } from '../store/recipesStore';
import type { RootStackParamList } from '../navigation/RootStack';

type Props = NativeStackScreenProps<RootStackParamList, 'CookMode'>;

export function CookModeScreen({ route, navigation }: Props) {
  useKeepAwake();
  const { id } = route.params;
  const recipe = useRecipesStore((s) => s.recipes[id]);
  const markCooked = useRecipesStore((s) => s.markCooked);
  const insets = useSafeAreaInsets();

  const originalServings = recipe?.servings ?? 0;
  const [currentServings, setCurrentServings] = useState<number>(
    originalServings > 0 ? originalServings : 0,
  );
  const [struckIngredients, setStruckIngredients] = useState<Set<string>>(
    new Set(),
  );
  const [struckSteps, setStruckSteps] = useState<Set<string>>(new Set());

  useEffect(() => {
    if (!recipe) navigation.goBack();
  }, [recipe, navigation]);

  const scaleFactor = useMemo(() => {
    if (!originalServings || !currentServings) return 1;
    return currentServings / originalServings;
  }, [currentServings, originalServings]);

  const currentStepId = useMemo(() => {
    if (!recipe) return undefined;
    const found = recipe.steps.find((s) => !struckSteps.has(s.id));
    return found?.id;
  }, [recipe, struckSteps]);

  if (!recipe) return <View style={styles.container} />;

  const toggleIngredient = (id: string) => {
    setStruckIngredients((prev) => {
      const next = new Set(prev);
      if (next.has(id)) next.delete(id);
      else next.add(id);
      return next;
    });
  };

  const toggleStep = (id: string) => {
    setStruckSteps((prev) => {
      const next = new Set(prev);
      if (next.has(id)) next.delete(id);
      else next.add(id);
      return next;
    });
  };

  const handleExit = () => {
    const didAnything =
      struckIngredients.size > 0 || struckSteps.size > 0;
    if (!didAnything) {
      navigation.goBack();
      return;
    }
    Alert.alert('Mark as cooked?', 'Record this as a time you cooked this recipe.', [
      { text: 'Not this time', style: 'cancel', onPress: () => navigation.goBack() },
      {
        text: 'Mark cooked',
        style: 'default',
        onPress: () => {
          markCooked(recipe.id);
          navigation.goBack();
        },
      },
    ]);
  };

  const canScale = originalServings > 0;
  const stepServings = () => {
    if (!canScale) return;
    setCurrentServings((n) => Math.max(1, n - 1));
  };
  const bumpServings = () => {
    if (!canScale) return;
    setCurrentServings((n) => Math.min(99, n + 1));
  };

  return (
    <View style={[styles.container, { paddingTop: insets.top + spacing.sm }]}>
      <View style={styles.topBar}>
        <Pressable
          onPress={handleExit}
          hitSlop={12}
          accessibilityLabel="Exit cook mode"
          style={styles.closeBtn}
        >
          <X size={24} color={colors.textPrimary} strokeWidth={2} />
        </Pressable>
        <Text style={styles.topTitle} numberOfLines={1}>
          {recipe.title}
        </Text>
        <View style={styles.topSpacer} />
      </View>

      <ScrollView
        contentContainerStyle={[
          styles.content,
          { paddingBottom: insets.bottom + spacing.xxxl },
        ]}
      >
        {canScale ? (
          <View style={styles.scaler}>
            <Pressable
              onPress={stepServings}
              hitSlop={10}
              style={styles.scalerBtn}
              accessibilityLabel="Decrease servings"
              disabled={currentServings <= 1}
            >
              <Minus
                size={18}
                color={currentServings <= 1 ? colors.divider : colors.textPrimary}
                strokeWidth={2.5}
              />
            </Pressable>
            <View style={styles.scalerCenter}>
              <Text style={styles.scalerCount}>{currentServings}</Text>
              <Text style={styles.scalerLabel}>
                serving{currentServings === 1 ? '' : 's'}
                {scaleFactor !== 1
                  ? `  ·  ${scaleFactor.toFixed(scaleFactor % 1 === 0 ? 0 : 2).replace(/\.?0+$/, '')}x`
                  : ''}
              </Text>
            </View>
            <Pressable
              onPress={bumpServings}
              hitSlop={10}
              style={styles.scalerBtn}
              accessibilityLabel="Increase servings"
            >
              <Plus size={18} color={colors.textPrimary} strokeWidth={2.5} />
            </Pressable>
          </View>
        ) : null}

        {recipe.ingredients.length > 0 ? (
          <View>
            <Text style={styles.sectionHeading}>Ingredients</Text>
            <View style={styles.list}>
              {recipe.ingredients.map((ingredient) => {
                const struck = struckIngredients.has(ingredient.id);
                const scaledQty = scaleQuantity(ingredient.quantity, scaleFactor);
                return (
                  <Pressable
                    key={ingredient.id}
                    onPress={() => toggleIngredient(ingredient.id)}
                    style={({ pressed }) => [
                      styles.ingredientRow,
                      pressed && styles.rowPressed,
                    ]}
                  >
                    <View
                      style={[styles.dot, struck && styles.dotStruck]}
                    />
                    <Text
                      style={[
                        styles.ingredientText,
                        struck && styles.textStruck,
                      ]}
                    >
                      {[scaledQty, ingredient.unit, ingredient.name]
                        .filter(Boolean)
                        .join(' ')}
                    </Text>
                  </Pressable>
                );
              })}
            </View>
          </View>
        ) : null}

        {recipe.steps.length > 0 ? (
          <View>
            <Text style={styles.sectionHeading}>Steps</Text>
            <View style={styles.list}>
              {recipe.steps.map((step, idx) => {
                const struck = struckSteps.has(step.id);
                const isCurrent = step.id === currentStepId;
                return (
                  <Pressable
                    key={step.id}
                    onPress={() => toggleStep(step.id)}
                    style={({ pressed }) => [
                      styles.stepRow,
                      isCurrent && styles.stepCurrent,
                      pressed && styles.rowPressed,
                    ]}
                  >
                    <Text
                      style={[styles.stepNumber, struck && styles.textStruck]}
                    >
                      {idx + 1}
                    </Text>
                    <Text
                      style={[styles.stepText, struck && styles.textStruck]}
                    >
                      {step.text}
                    </Text>
                  </Pressable>
                );
              })}
            </View>
          </View>
        ) : null}
      </ScrollView>

      <View style={[styles.bottomBar, { paddingBottom: insets.bottom + spacing.md }]}>
        <Pressable
          onPress={() => {
            markCooked(recipe.id);
            navigation.goBack();
          }}
          style={styles.doneBtn}
          accessibilityLabel="Mark as cooked and exit"
        >
          <Text style={styles.doneBtnText}>Mark as Cooked</Text>
        </Pressable>
      </View>
    </View>
  );
}

const styles = StyleSheet.create({
  container: {
    flex: 1,
    backgroundColor: colors.cookModeBackground,
  },
  topBar: {
    flexDirection: 'row',
    alignItems: 'center',
    paddingHorizontal: spacing.lg,
    paddingBottom: spacing.md,
    gap: spacing.md,
  },
  closeBtn: {
    width: 40,
    height: 40,
    borderRadius: radius.full,
    alignItems: 'center',
    justifyContent: 'center',
    backgroundColor: colors.surface,
  },
  topTitle: {
    ...textStyles.sectionHeading,
    fontFamily: fontFamilies.displayBold,
    color: colors.textPrimary,
    flex: 1,
    textAlign: 'center',
  },
  topSpacer: {
    width: 40,
  },
  content: {
    padding: spacing.lg,
    gap: spacing.md,
  },
  scaler: {
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'space-between',
    backgroundColor: colors.surface,
    borderRadius: radius.lg,
    paddingHorizontal: spacing.md,
    paddingVertical: spacing.md,
    gap: spacing.md,
  },
  scalerBtn: {
    width: 44,
    height: 44,
    borderRadius: radius.full,
    backgroundColor: colors.background,
    alignItems: 'center',
    justifyContent: 'center',
  },
  scalerCenter: {
    flex: 1,
    alignItems: 'center',
  },
  scalerCount: {
    fontFamily: fontFamilies.displayBold,
    fontSize: 24,
    lineHeight: 28,
    color: colors.textPrimary,
    fontVariant: ['tabular-nums'],
  },
  scalerLabel: {
    ...textStyles.caption,
    color: colors.textSecondary,
  },
  sectionHeading: {
    ...textStyles.sectionHeading,
    fontFamily: fontFamilies.displayBold,
    color: colors.textPrimary,
    marginTop: spacing.lg,
    marginBottom: spacing.sm,
  },
  list: {
    gap: spacing.xs,
  },
  ingredientRow: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: spacing.md,
    paddingVertical: spacing.md,
    paddingHorizontal: spacing.md,
    backgroundColor: colors.surface,
    borderRadius: radius.md,
  },
  rowPressed: {
    opacity: 0.7,
  },
  dot: {
    width: 10,
    height: 10,
    borderRadius: 5,
    backgroundColor: colors.accent,
  },
  dotStruck: {
    backgroundColor: colors.success,
  },
  ingredientText: {
    ...textStyles.ingredientCook,
    color: colors.textPrimary,
    flex: 1,
  },
  textStruck: {
    textDecorationLine: 'line-through',
    color: colors.textSecondary,
  },
  stepRow: {
    flexDirection: 'row',
    alignItems: 'flex-start',
    gap: spacing.md,
    paddingVertical: spacing.md,
    paddingHorizontal: spacing.md,
    backgroundColor: colors.surface,
    borderRadius: radius.md,
    borderWidth: 2,
    borderColor: 'transparent',
  },
  stepCurrent: {
    borderColor: colors.accent,
  },
  stepNumber: {
    fontFamily: fontFamilies.displayBold,
    fontSize: 20,
    lineHeight: 30,
    color: colors.accent,
    minWidth: 28,
    fontVariant: ['tabular-nums'],
  },
  stepText: {
    ...textStyles.ingredientCook,
    color: colors.textPrimary,
    flex: 1,
  },
  bottomBar: {
    position: 'absolute',
    left: 0,
    right: 0,
    bottom: 0,
    padding: spacing.lg,
    paddingTop: spacing.md,
    backgroundColor: colors.cookModeBackground,
    borderTopWidth: 1,
    borderTopColor: colors.divider,
  },
  doneBtn: {
    backgroundColor: colors.success,
    paddingVertical: spacing.md,
    borderRadius: radius.md,
    alignItems: 'center',
    justifyContent: 'center',
  },
  doneBtnText: {
    fontFamily: fontFamilies.bodySemibold,
    fontSize: 17,
    color: '#FFFDF8',
  },
});
