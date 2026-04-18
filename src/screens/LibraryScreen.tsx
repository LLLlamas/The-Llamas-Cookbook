import { useMemo } from 'react';
import { FlatList, Pressable, StyleSheet, View } from 'react-native';
import { Plus } from 'lucide-react-native';
import type { NativeStackScreenProps } from '@react-navigation/native-stack';
import { useRecipesStore } from '../store/recipesStore';
import { EmptyState } from '../components/EmptyState';
import { RecipeCard } from '../components/RecipeCard';
import { colors } from '../theme/colors';
import { radius, shadow, spacing } from '../theme/spacing';
import type { RootStackParamList } from '../navigation/RootStack';

type Props = NativeStackScreenProps<RootStackParamList, 'Library'>;

export function LibraryScreen({ navigation }: Props) {
  const hydrated = useRecipesStore((s) => s.hydrated);
  const recipes = useRecipesStore((s) => s.recipes);

  const list = useMemo(
    () =>
      Object.values(recipes).sort((a, b) =>
        b.createdAt.localeCompare(a.createdAt),
      ),
    [recipes],
  );

  const openEditor = () => navigation.navigate('RecipeEditor', {});

  if (!hydrated) {
    return <View style={styles.container} />;
  }

  return (
    <View style={styles.container}>
      {list.length === 0 ? (
        <EmptyState
          title="No recipes yet"
          subtitle="Tap the + button to add your first recipe."
        />
      ) : (
        <FlatList
          data={list}
          keyExtractor={(r) => r.id}
          contentContainerStyle={styles.listContent}
          ItemSeparatorComponent={() => <View style={styles.sep} />}
          renderItem={({ item }) => (
            <RecipeCard
              recipe={item}
              onPress={() => navigation.navigate('RecipeDetail', { id: item.id })}
            />
          )}
        />
      )}
      <Pressable
        accessibilityLabel="Add recipe"
        style={({ pressed }) => [styles.fab, pressed && styles.fabPressed]}
        onPress={openEditor}
      >
        <Plus color="#FFFDF8" size={28} strokeWidth={2.25} />
      </Pressable>
    </View>
  );
}

const styles = StyleSheet.create({
  container: {
    flex: 1,
    backgroundColor: colors.background,
  },
  listContent: {
    padding: spacing.lg,
  },
  sep: {
    height: spacing.md,
  },
  fab: {
    position: 'absolute',
    right: spacing.xl,
    bottom: spacing.xl,
    width: 60,
    height: 60,
    borderRadius: radius.full,
    backgroundColor: colors.accent,
    alignItems: 'center',
    justifyContent: 'center',
    ...shadow.card,
  },
  fabPressed: {
    opacity: 0.85,
  },
});
