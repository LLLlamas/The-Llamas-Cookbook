import { useEffect, useMemo, useRef, useState } from 'react';
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
import * as Haptics from 'expo-haptics';
import {
  ArrowLeft,
  Check,
  ChevronRight,
  Minus,
  Plus,
  Timer,
  X,
} from 'lucide-react-native';
import type { NativeStackScreenProps } from '@react-navigation/native-stack';
import { LlamaMascot } from '../components/LlamaMascot';
import { colors } from '../theme/colors';
import { radius, spacing } from '../theme/spacing';
import { fontFamilies, textStyles } from '../theme/typography';
import { scaleQuantity } from '../lib/scaleQuantity';
import { useRecipesStore } from '../store/recipesStore';
import type { RootStackParamList } from '../navigation/RootStack';

type Props = NativeStackScreenProps<RootStackParamList, 'CookMode'>;

type Phase = 'prep' | 'cook';

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
  const [phase, setPhase] = useState<Phase>(() =>
    (recipe?.ingredients.length ?? 0) > 0 ? 'prep' : 'cook',
  );
  const [timerEndsAt, setTimerEndsAt] = useState<number | null>(null);
  const [timerStepId, setTimerStepId] = useState<string | null>(null);
  const [now, setNow] = useState(Date.now());
  const timerFiredRef = useRef(false);

  useEffect(() => {
    if (!recipe) navigation.goBack();
  }, [recipe, navigation]);

  useEffect(() => {
    if (!timerEndsAt) return;
    const id = setInterval(() => setNow(Date.now()), 1000);
    return () => clearInterval(id);
  }, [timerEndsAt]);

  useEffect(() => {
    if (!timerEndsAt || timerFiredRef.current) return;
    if (now >= timerEndsAt) {
      timerFiredRef.current = true;
      setTimerEndsAt(null);
      setTimerStepId(null);
      Haptics.notificationAsync(Haptics.NotificationFeedbackType.Success).catch(
        () => {},
      );
      Alert.alert(
        'Oven timer done!',
        'Your food is ready to come out of the oven.',
        [{ text: 'Got it', onPress: () => { timerFiredRef.current = false; } }],
      );
    }
  }, [now, timerEndsAt]);

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

  const totalIngredients = recipe.ingredients.length;
  const readyCount = struckIngredients.size;
  const hasSteps = recipe.steps.length > 0;

  const ovenMins = recipe.ovenTimeMinutes ?? 0;
  const canOvenTimer = ovenMins > 0;
  const secondsLeft = timerEndsAt
    ? Math.max(0, Math.ceil((timerEndsAt - now) / 1000))
    : 0;
  const formatClock = (secs: number) => {
    const m = Math.floor(secs / 60);
    const s = secs % 60;
    return `${m}:${String(s).padStart(2, '0')}`;
  };
  const isOvenStep = (text: string) => /oven|bake/i.test(text);
  const startOvenTimer = (stepId: string) => {
    if (!canOvenTimer) return;
    timerFiredRef.current = false;
    setTimerStepId(stepId);
    setTimerEndsAt(Date.now() + ovenMins * 60 * 1000);
    Haptics.impactAsync(Haptics.ImpactFeedbackStyle.Medium).catch(() => {});
  };
  const cancelOvenTimer = () => {
    setTimerEndsAt(null);
    setTimerStepId(null);
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
        <View style={styles.topSpacer}>
          <LlamaMascot size={32} />
        </View>
      </View>

      <View style={styles.phaseHeader}>
        {phase === 'cook' && totalIngredients > 0 ? (
          <Pressable
            onPress={() => setPhase('prep')}
            hitSlop={10}
            style={styles.backToPrep}
            accessibilityLabel="Back to ingredients"
          >
            <ArrowLeft size={16} color={colors.textSecondary} strokeWidth={2} />
            <Text style={styles.backToPrepText}>Ingredients</Text>
          </Pressable>
        ) : null}
        <Text style={styles.phaseTitle}>
          {phase === 'prep' ? 'Got everything?' : "Let's cook"}
        </Text>
        <Text style={styles.phaseSubtitle}>
          {phase === 'prep'
            ? 'Check off each ingredient as you line it up.'
            : hasSteps
              ? 'Tap each step as you finish it.'
              : 'No steps listed — cook freestyle and mark it done when finished.'}
        </Text>
      </View>

      <ScrollView
        contentContainerStyle={[
          styles.content,
          { paddingBottom: insets.bottom + spacing.xxxl },
        ]}
      >
        {phase === 'prep' ? (
          <>
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

            <View style={styles.list}>
              {recipe.ingredients.map((ingredient) => {
                const struck = struckIngredients.has(ingredient.id);
                const scaledQty = scaleQuantity(ingredient.quantity, scaleFactor);
                return (
                  <Pressable
                    key={ingredient.id}
                    onPress={() => toggleIngredient(ingredient.id)}
                    style={({ pressed }) => [
                      styles.checkRow,
                      struck && styles.checkRowDone,
                      pressed && styles.rowPressed,
                    ]}
                  >
                    <View
                      style={[styles.checkbox, struck && styles.checkboxDone]}
                    >
                      {struck ? (
                        <Check size={16} color="#FFFDF8" strokeWidth={3} />
                      ) : null}
                    </View>
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
          </>
        ) : (
          <View style={styles.list}>
            {recipe.steps.map((step, idx) => {
              const struck = struckSteps.has(step.id);
              const isCurrent = step.id === currentStepId;
              const oven = isOvenStep(step.text);
              const thisTiming =
                timerStepId === step.id && timerEndsAt != null;
              const anotherTiming =
                timerEndsAt != null && timerStepId !== step.id;
              return (
                <View
                  key={step.id}
                  style={[
                    styles.stepRow,
                    isCurrent && styles.stepCurrent,
                    struck && styles.stepDone,
                  ]}
                >
                  <Pressable
                    onPress={() => toggleStep(step.id)}
                    style={({ pressed }) => [
                      styles.stepHeader,
                      pressed && styles.rowPressed,
                    ]}
                  >
                    <View
                      style={[
                        styles.stepNumberBadge,
                        struck && styles.stepNumberBadgeDone,
                      ]}
                    >
                      {struck ? (
                        <Check size={16} color="#FFFDF8" strokeWidth={3} />
                      ) : (
                        <Text style={styles.stepNumberText}>{idx + 1}</Text>
                      )}
                    </View>
                    <Text
                      style={[styles.stepText, struck && styles.textStruck]}
                    >
                      {step.text}
                    </Text>
                  </Pressable>
                  {oven && canOvenTimer ? (
                    thisTiming ? (
                      <Pressable
                        onPress={cancelOvenTimer}
                        style={styles.timerActiveBtn}
                        accessibilityLabel="Cancel oven timer"
                      >
                        <Timer size={16} color="#FFFDF8" strokeWidth={2.25} />
                        <Text style={styles.timerActiveText}>
                          {formatClock(secondsLeft)}  ·  tap to cancel
                        </Text>
                      </Pressable>
                    ) : !anotherTiming ? (
                      <Pressable
                        onPress={() => startOvenTimer(step.id)}
                        style={styles.timerBtn}
                        accessibilityLabel={`Start ${ovenMins}-minute oven timer`}
                      >
                        <Timer
                          size={16}
                          color={colors.accent}
                          strokeWidth={2.25}
                        />
                        <Text style={styles.timerBtnText}>
                          Start {ovenMins}-min oven timer
                        </Text>
                      </Pressable>
                    ) : null
                  ) : null}
                </View>
              );
            })}
          </View>
        )}
      </ScrollView>

      <View style={[styles.bottomBar, { paddingBottom: insets.bottom + spacing.md }]}>
        {phase === 'prep' && hasSteps ? (
          <Pressable
            onPress={() => setPhase('cook')}
            style={styles.primaryBtn}
            accessibilityLabel="Start cooking"
          >
            <Text style={styles.primaryBtnText}>
              Start cooking
              {totalIngredients > 0 ? `  ·  ${readyCount}/${totalIngredients}` : ''}
            </Text>
            <ChevronRight size={20} color="#FFFDF8" strokeWidth={2.5} />
          </Pressable>
        ) : (
          <Pressable
            onPress={() => {
              markCooked(recipe.id);
              navigation.goBack();
            }}
            style={[styles.primaryBtn, styles.doneBtn]}
            accessibilityLabel="Mark as cooked and exit"
          >
            <Check size={20} color="#FFFDF8" strokeWidth={2.5} />
            <Text style={styles.primaryBtnText}>Mark as cooked</Text>
          </Pressable>
        )}
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
    paddingBottom: spacing.sm,
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
    alignItems: 'center',
    justifyContent: 'center',
  },
  phaseHeader: {
    paddingHorizontal: spacing.lg,
    paddingBottom: spacing.md,
    gap: 2,
  },
  backToPrep: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: spacing.xs,
    marginBottom: spacing.xs,
    alignSelf: 'flex-start',
  },
  backToPrepText: {
    ...textStyles.caption,
    color: colors.textSecondary,
  },
  phaseTitle: {
    fontFamily: fontFamilies.displayBold,
    fontSize: 24,
    lineHeight: 30,
    color: colors.textPrimary,
  },
  phaseSubtitle: {
    ...textStyles.body,
    color: colors.textSecondary,
  },
  content: {
    padding: spacing.lg,
    paddingTop: spacing.sm,
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
  list: {
    gap: spacing.sm,
  },
  checkRow: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: spacing.md,
    paddingVertical: spacing.md,
    paddingHorizontal: spacing.md,
    backgroundColor: colors.surface,
    borderRadius: radius.md,
    borderWidth: 1,
    borderColor: colors.divider,
  },
  checkRowDone: {
    borderColor: colors.success,
    backgroundColor: colors.background,
  },
  rowPressed: {
    opacity: 0.7,
  },
  checkbox: {
    width: 24,
    height: 24,
    borderRadius: radius.sm,
    borderWidth: 2,
    borderColor: colors.accent,
    backgroundColor: colors.background,
    alignItems: 'center',
    justifyContent: 'center',
  },
  checkboxDone: {
    backgroundColor: colors.success,
    borderColor: colors.success,
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
    backgroundColor: colors.surface,
    borderRadius: radius.md,
    borderWidth: 2,
    borderColor: colors.divider,
    overflow: 'hidden',
  },
  stepHeader: {
    flexDirection: 'row',
    alignItems: 'flex-start',
    gap: spacing.md,
    paddingVertical: spacing.md,
    paddingHorizontal: spacing.md,
  },
  stepCurrent: {
    borderColor: colors.accent,
  },
  stepDone: {
    borderColor: colors.success,
    backgroundColor: colors.background,
  },
  timerBtn: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: spacing.xs,
    marginHorizontal: spacing.md,
    marginBottom: spacing.md,
    paddingHorizontal: spacing.md,
    paddingVertical: spacing.sm,
    backgroundColor: colors.background,
    borderRadius: radius.md,
    borderWidth: 1,
    borderColor: colors.accent,
    alignSelf: 'flex-start',
  },
  timerBtnText: {
    fontFamily: fontFamilies.bodySemibold,
    fontSize: 14,
    color: colors.accent,
  },
  timerActiveBtn: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: spacing.xs,
    marginHorizontal: spacing.md,
    marginBottom: spacing.md,
    paddingHorizontal: spacing.md,
    paddingVertical: spacing.sm,
    backgroundColor: colors.accent,
    borderRadius: radius.md,
    alignSelf: 'flex-start',
  },
  timerActiveText: {
    fontFamily: fontFamilies.bodySemibold,
    fontSize: 14,
    color: '#FFFDF8',
    fontVariant: ['tabular-nums'],
  },
  stepNumberBadge: {
    width: 30,
    height: 30,
    borderRadius: radius.full,
    backgroundColor: colors.background,
    borderWidth: 2,
    borderColor: colors.accent,
    alignItems: 'center',
    justifyContent: 'center',
  },
  stepNumberBadgeDone: {
    backgroundColor: colors.success,
    borderColor: colors.success,
  },
  stepNumberText: {
    fontFamily: fontFamilies.displayBold,
    fontSize: 15,
    color: colors.accent,
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
  primaryBtn: {
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'center',
    gap: spacing.sm,
    backgroundColor: colors.accent,
    paddingVertical: spacing.md,
    borderRadius: radius.md,
  },
  doneBtn: {
    backgroundColor: colors.success,
  },
  primaryBtnText: {
    fontFamily: fontFamilies.bodySemibold,
    fontSize: 17,
    color: '#FFFDF8',
  },
});
