part of 'parser.dart';

class ValueVisitor extends RecursiveAstVisitor<void> {
  final List<String> identifier = [];

  @override
  void visitSimpleIdentifier(SimpleIdentifier node) {
    identifier.add(node.name);
  }
}

class AnnotationVisitor extends SimpleAstVisitor<void> {
  static const validFields = ['tables', 'views'];
  static const annotationName = 'DriftAccessor';

  final Map<String, List<String>> values = {};

  @override
  void visitNamedExpression(NamedExpression node) {
    final name = node.name.label.name;
    if (!validFields.contains(name)) return;

    final visitor = ValueVisitor();
    node.expression.visitChildren(visitor);

    values[name] = visitor.identifier;
  }

  @override
  void visitAnnotation(Annotation node) {
    if (node.name.name != annotationName) return;

    node.arguments?.visitChildren(this);
  }
}

class UseDaoParser {
  final ParseDartStep step;

  UseDaoParser(this.step);

  AstNode? getAstNodeFromElement(Element? element) {
    if (element == null) return null;

    final session = element.session;
    final library = element.library;
    if (session == null || library == null) return null;

    final parsedLibResult = session.getParsedLibraryByElement(library);
    if (parsedLibResult is! ParsedLibraryResult) return null;
    return parsedLibResult.getElementDeclaration(element)?.node;
  }

  /// If [element] has a `@UseDao` annotation, parses the database model
  /// declared by that class and the referenced tables.
  Future<Dao?> parseDao(ClassElement element, ConstantReader annotation) async {
    final dbType = element.allSupertypes
        .firstWhereOrNull((i) => i.element.name == 'DatabaseAccessor');

    if (dbType == null) {
      step.reportError(ErrorInDartCode(
        affectedElement: element,
        severity: Severity.criticalError,
        message: 'This class must inherit from DatabaseAccessor',
      ));
      return null;
    }

    // inherits from DatabaseAccessor<T>, we want to know which T
    final dbImpl = dbType.typeArguments.single;
    if (dbImpl.isDynamic) {
      step.reportError(ErrorInDartCode(
        affectedElement: element,
        severity: Severity.criticalError,
        message: 'This class must inherit from DatabaseAccessor<T>, where T '
            'is an actual type of a database.',
      ));
      return null;
    }

    final tableTypes = annotation
            .peek('tables')
            ?.listValue
            .map((obj) => obj.toTypeValue())
            .whereType<DartType>() ??
        const [];
    final queryStrings = annotation.peek('queries')?.mapValue ?? {};

    final viewTypes = annotation
            .peek('views')
            ?.listValue
            .map((obj) => obj.toTypeValue())
            .whereType<DartType>() ??
        const [];

    final includes = annotation
            .read('include')
            .objectValue
            .toSetValue()
            ?.map((e) => e.toStringValue())
            .whereType<String>()
            .toList() ??
        [];

    final parsedTables = await step.parseTables(tableTypes, element);
    final parsedViews = await step.parseViews(viewTypes, element, parsedTables);
    final parsedQueries = step.readDeclaredQueries(queryStrings.cast());

    final astVisitor = AnnotationVisitor();
    getAstNodeFromElement(element)?.visitChildren(astVisitor);

    final astTables = astVisitor.values['tables'] ?? [];
    final astViews = astVisitor.values['tables'] ?? [];

    astTables.removeWhere((e) => parsedTables.any((t) => t.dartTypeName == e));
    astViews.removeWhere((e) => parsedViews.any((v) => v.dartTypeName == e));

    return Dao(
      declaration: DatabaseOrDaoDeclaration(element, step.file),
      dbClass: dbImpl,
      declaredTables: parsedTables,
      declaredViews: parsedViews,
      declaredIncludes: includes,
      declaredQueries: parsedQueries,
      astTables: astTables,
      astViews: astViews,
    );
  }
}
